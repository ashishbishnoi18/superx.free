defmodule SuperXWeb.BillingController do
  @moduledoc """
  Starts Stripe checkout and the customer portal.

  Both are redirects to Stripe rather than forms here: this app never sees a
  card number, which is the whole reason for using hosted checkout.
  """

  use SuperXWeb, :controller

  alias SuperX.Billing
  alias SuperX.Billing.Stripe

  def checkout(conn, %{"price" => key}) do
    user = conn.assigns.current_scope.user

    with %{id: price_id} <- Stripe.price_by_key(key),
         {:ok, %{"url" => url}} <-
           Stripe.create_checkout_session(user, price_id, %{
             success: url(~p"/billing?checkout=done"),
             cancel: url(~p"/billing")
           }) do
      redirect(conn, external: url)
    else
      _unavailable ->
        conn
        |> put_flash(:error, "Could not open checkout. Nothing has been charged.")
        |> redirect(to: ~p"/billing")
    end
  end

  def portal(conn, _params) do
    user = conn.assigns.current_scope.user

    with %{provider_customer_id: customer} when is_binary(customer) <-
           Billing.get_subscription(user),
         {:ok, %{"url" => url}} <- Stripe.create_portal_session(customer, url(~p"/billing")) do
      redirect(conn, external: url)
    else
      _no_customer ->
        conn
        |> put_flash(:error, "No billing account yet. Subscribe first.")
        |> redirect(to: ~p"/billing")
    end
  end
end
