defmodule SuperX.Billing.StripeTest do
  @moduledoc """
  Webhook signatures decide whether a stranger can grant themselves a paid
  plan by POSTing JSON, so every rejection path is pinned here.
  """

  # Not async: these swap application config.
  use ExUnit.Case, async: false

  alias SuperX.Billing.Stripe

  @secret "whsec_test_secret"

  setup do
    previous = Application.get_env(:superx, Stripe, [])

    Application.put_env(
      :superx,
      Stripe,
      Keyword.merge(previous,
        secret_key: "sk_test_x",
        webhook_secret: @secret,
        price_keys_included: "price_keys",
        price_byo: "price_byo"
      )
    )

    on_exit(fn -> Application.put_env(:superx, Stripe, previous) end)
    :ok
  end

  describe "verify_webhook/3" do
    test "accepts a correctly signed body" do
      body = ~s({"type":"checkout.session.completed"})
      now = 1_800_000_000

      assert {:ok, %{"type" => "checkout.session.completed"}} =
               Stripe.verify_webhook(body, header(body, now), now)
    end

    test "rejects a body that changed after signing" do
      # The attack this exists to stop: a valid signature lifted from one
      # event and pasted onto a different, more generous payload.
      now = 1_800_000_000
      header = header(~s({"type":"invoice.paid"}), now)

      assert {:error, :invalid_signature} =
               Stripe.verify_webhook(~s({"type":"checkout.session.completed"}), header, now)
    end

    test "rejects a replay of an old but genuine request" do
      body = ~s({"type":"checkout.session.completed"})
      signed_at = 1_800_000_000

      assert {:error, :timestamp_out_of_tolerance} =
               Stripe.verify_webhook(body, header(body, signed_at), signed_at + 3600)
    end

    test "rejects a missing or malformed signature header" do
      body = ~s({"type":"checkout.session.completed"})

      assert {:error, :invalid_signature} = Stripe.verify_webhook(body, nil, 1_800_000_000)
      assert {:error, :invalid_signature} = Stripe.verify_webhook(body, "garbage", 1_800_000_000)
    end

    test "rejects everything when no webhook secret is configured" do
      config = Application.get_env(:superx, Stripe, [])
      Application.put_env(:superx, Stripe, Keyword.put(config, :webhook_secret, nil))

      body = ~s({"type":"checkout.session.completed"})
      now = 1_800_000_000

      assert {:error, :invalid_signature} = Stripe.verify_webhook(body, header(body, now), now)
    end
  end

  describe "configured?/0 and prices/0" do
    test "hides prices whose ids are unset rather than offering a broken checkout" do
      config = Application.get_env(:superx, Stripe, [])
      Application.put_env(:superx, Stripe, Keyword.put(config, :price_byo, nil))

      assert Enum.map(Stripe.prices(), & &1.key) == ["keys_included"]
    end

    test "is unconfigured without a secret key" do
      config = Application.get_env(:superx, Stripe, [])
      Application.put_env(:superx, Stripe, Keyword.put(config, :secret_key, nil))

      refute Stripe.configured?()
    end
  end

  defp header(body, timestamp) do
    signature =
      :crypto.mac(:hmac, :sha256, @secret, "#{timestamp}.#{body}") |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end
end
