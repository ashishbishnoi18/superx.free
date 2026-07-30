defmodule SuperXWeb.StripeWebhookControllerTest do
  use SuperXWeb.ConnCase, async: false

  import SuperX.Fixtures

  alias SuperX.Billing

  @secret "whsec_test_secret"

  setup do
    previous = Application.get_env(:superx, SuperX.Billing, [])

    Application.put_env(
      :superx,
      SuperX.Billing,
      Keyword.put(previous, :stripe_webhook_secret, @secret)
    )

    on_exit(fn -> Application.put_env(:superx, SuperX.Billing, previous) end)

    user_fixture()
  end

  defp sign(body, timestamp \\ System.system_time(:second)) do
    signature =
      :hmac
      |> :crypto.mac(:sha256, @secret, "#{timestamp}.#{body}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end

  defp post_webhook(conn, body, signature) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", signature)
    |> post(~p"/webhooks/stripe", body)
  end

  defp subscription_event(user, overrides \\ %{}) do
    Jason.encode!(%{
      type: "customer.subscription.updated",
      data: %{
        object:
          Map.merge(
            %{
              id: "sub_test_123",
              customer: "cus_test_123",
              status: "active",
              metadata: %{user_id: user.id},
              items: %{
                data: [
                  %{price: %{id: "price_test", unit_amount: 2900, currency: "usd",
                             recurring: %{interval: "month"}}}
                ]
              }
            },
            overrides
          )
      }
    })
  end

  test "applies a subscription update when the signature is valid", %{conn: conn, user: user} do
    body = subscription_event(user)

    conn = post_webhook(conn, body, sign(body))

    assert response(conn, 200)

    subscription = Billing.get_subscription(user)
    assert subscription.provider_subscription_id == "sub_test_123"
    assert subscription.provider_customer_id == "cus_test_123"
    assert subscription.status == "active"
    assert subscription.amount_cents == 2900
  end

  test "rejects a forged signature", %{conn: conn, user: user} do
    body = subscription_event(user)

    conn = post_webhook(conn, body, "t=#{System.system_time(:second)},v1=deadbeef")

    assert response(conn, 400)
    # The plan must not have been granted.
    assert Billing.get_subscription(user).provider_subscription_id == nil
  end

  test "rejects a missing signature", %{conn: conn, user: user} do
    conn = post_webhook(conn, subscription_event(user), "")

    assert response(conn, 400)
  end

  test "rejects a replayed event outside the tolerance window", %{conn: conn, user: user} do
    body = subscription_event(user)
    stale = System.system_time(:second) - 3600

    conn = post_webhook(conn, body, sign(body, stale))

    assert response(conn, 400)
    assert Billing.get_subscription(user).provider_subscription_id == nil
  end

  test "cancellation drops the user back to free", %{conn: conn, user: user} do
    {:ok, _} = Billing.upsert_subscription(user, %{tier: "ultra", status: "active"})

    body =
      Jason.encode!(%{
        type: "customer.subscription.deleted",
        data: %{object: %{id: "sub_test_123", metadata: %{user_id: user.id}}}
      })

    conn = post_webhook(conn, body, sign(body))

    assert response(conn, 200)

    subscription = Billing.get_subscription(user)
    assert subscription.tier == "free"
    assert subscription.status == "canceled"
    assert Billing.tier(user) == "free"
  end
end
