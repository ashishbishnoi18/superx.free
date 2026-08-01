defmodule SuperX.Billing.CheckoutTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.Billing
  alias SuperX.Billing.Checkout
  alias SuperX.Teams

  setup do
    previous_billing = Application.get_env(:superx, Billing, [])
    previous_checkout = Application.get_env(:superx, Checkout, [])

    Application.put_env(
      :superx,
      Billing,
      Keyword.put(previous_billing, :stripe_secret_key, "sk_test_teams")
    )

    Application.put_env(
      :superx,
      Checkout,
      previous_checkout
      |> Keyword.put(:price_ids, %{{"pro", "month"} => "price_plan_pro_month"})
      |> Keyword.put(:seat_price_ids, %{{"pro", "month"} => "price_seat_pro_month"})
    )

    on_exit(fn ->
      Application.put_env(:superx, Billing, previous_billing)
      Application.put_env(:superx, Checkout, previous_checkout)
    end)

    :ok
  end

  test "checkout sends accepted seats as a second recurring line item" do
    %{user: owner} = user_fixture()
    %{user: first} = user_fixture()
    %{user: second} = user_fixture()

    accept(owner, first, "first@example.com")
    accept(owner, second, "second@example.com")

    Req.Test.stub(Checkout, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

      assert params["line_items[0][price]"] == "price_plan_pro_month"
      assert params["line_items[0][quantity]"] == "1"
      assert params["line_items[1][price]"] == "price_seat_pro_month"
      assert params["line_items[1][quantity]"] == "2"
      assert params["subscription_data[metadata][seat_count]"] == "2"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"url" => "https://checkout.stripe.test/session"})
      )
    end)

    assert {:ok, "https://checkout.stripe.test/session"} =
             Checkout.create_session(owner, "pro", :month)
  end

  test "a member cannot create a separately billed checkout" do
    %{user: owner} = user_fixture()
    %{user: member} = user_fixture()
    accept(owner, member, "member@example.com")

    assert {:error, :team_member} = Checkout.create_session(member, "pro", :month)
  end

  test "checkout refuses accepted seats when their Stripe price is missing" do
    %{user: owner} = user_fixture()
    %{user: member} = user_fixture()
    accept(owner, member, "member@example.com")

    config = Application.fetch_env!(:superx, Checkout)
    Application.put_env(:superx, Checkout, Keyword.put(config, :seat_price_ids, %{}))

    assert {:error, {:no_seat_price_for, "pro", :month}} =
             Checkout.create_session(owner, "pro", :month)
  end

  defp accept(owner, member, email) do
    {:ok, invitation, _url} = Teams.invite(owner, %{"email" => email})
    {:ok, _member} = Teams.accept_invitation(member, invitation.token)
  end
end
