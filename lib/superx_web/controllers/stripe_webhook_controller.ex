defmodule SuperXWeb.StripeWebhookController do
  @moduledoc """
  Receives Stripe events.

  Anything that verifies is applied and answered 200, including event types
  this app ignores: Stripe retries a non-2xx for days, so returning an error
  for an event we simply do not care about creates a queue that never drains.
  A bad signature is the one case that gets a 400.
  """

  use SuperXWeb, :controller

  require Logger

  alias SuperX.Billing
  alias SuperX.Billing.Stripe

  def create(conn, _params) do
    signature = conn |> get_req_header("stripe-signature") |> List.first()

    with raw when is_binary(raw) <- conn.assigns[:raw_body],
         {:ok, event} <- Stripe.verify_webhook(raw, signature) do
      case Billing.apply_stripe_event(event) do
        {:ok, _result} ->
          send_resp(conn, 200, "")

        {:error, reason} ->
          # A verified event that will not apply is our bug, not Stripe's.
          # Answering 200 stops the retry that would otherwise recover it.
          Logger.error("Stripe event #{event["type"]} could not be applied: #{inspect(reason)}")
          send_resp(conn, 500, "")
      end
    else
      {:error, reason} ->
        Logger.warning("Rejected a Stripe webhook: #{inspect(reason)}")
        send_resp(conn, 400, "")

      nil ->
        send_resp(conn, 400, "")
    end
  end
end
