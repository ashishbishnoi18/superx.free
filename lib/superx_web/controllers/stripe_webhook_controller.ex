defmodule SuperXWeb.StripeWebhookController do
  @moduledoc """
  Receives Stripe subscription lifecycle events.

  The signature is verified against the raw request body — see
  `SuperXWeb.Plugs.RawBody`, which caches it during parsing. Verifying a
  re-encoded body would fail, and skipping verification would let anyone
  grant themselves a plan by posting here.
  """

  use SuperXWeb, :controller

  require Logger

  alias SuperX.{Accounts, Billing}

  # Reject replayed events outside Stripe's recommended window.
  @tolerance_seconds 300

  def handle(conn, _params) do
    raw_body = conn.assigns[:raw_body] || ""
    signature = conn |> get_req_header("stripe-signature") |> List.first()

    with {:ok, secret} <- webhook_secret(),
         :ok <- verify(raw_body, signature, secret),
         {:ok, event} <- Jason.decode(raw_body) do
      process(event)
      send_resp(conn, 200, "ok")
    else
      {:error, :not_configured} ->
        send_resp(conn, 503, "billing not configured")

      {:error, reason} ->
        Logger.warning("Rejected Stripe webhook: #{inspect(reason)}")
        send_resp(conn, 400, "invalid")
    end
  end

  defp webhook_secret do
    case Application.get_env(:superx, SuperX.Billing, [])[:stripe_webhook_secret] do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :not_configured}
    end
  end

  # Stripe signs "<timestamp>.<body>" with HMAC-SHA256.
  defp verify(_body, nil, _secret), do: {:error, :missing_signature}

  defp verify(body, signature, secret) do
    parts =
      signature
      |> String.split(",")
      |> Map.new(fn part ->
        case String.split(part, "=", parts: 2) do
          [k, v] -> {k, v}
          _ -> {part, nil}
        end
      end)

    with {:ok, timestamp} <- fetch_timestamp(parts),
         :ok <- check_age(timestamp) do
      expected =
        :hmac
        |> :crypto.mac(:sha256, secret, "#{timestamp}.#{body}")
        |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(expected, parts["v1"] || "") do
        :ok
      else
        {:error, :signature_mismatch}
      end
    end
  end

  defp fetch_timestamp(%{"t" => t}) when is_binary(t) do
    case Integer.parse(t) do
      {timestamp, _} -> {:ok, timestamp}
      :error -> {:error, :bad_timestamp}
    end
  end

  defp fetch_timestamp(_), do: {:error, :bad_timestamp}

  defp check_age(timestamp) do
    if abs(System.system_time(:second) - timestamp) <= @tolerance_seconds do
      :ok
    else
      {:error, :stale_event}
    end
  end

  # --- Event handling ------------------------------------------------------

  defp process(%{"type" => type, "data" => %{"object" => object}})
       when type in [
              "checkout.session.completed",
              "customer.subscription.created",
              "customer.subscription.updated"
            ] do
    with %{} = user <- resolve_user(object) do
      Billing.upsert_subscription(user, subscription_attrs(object))
    else
      _ -> Logger.warning("Stripe #{type} for an unknown user")
    end
  end

  defp process(%{"type" => "customer.subscription.deleted", "data" => %{"object" => object}}) do
    with %{} = user <- resolve_user(object) do
      # Drop to free rather than deleting: history and the customer id
      # stay available for a future resubscribe.
      Billing.upsert_subscription(user, %{
        tier: "free",
        status: "canceled",
        canceled_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end
  end

  defp process(%{"type" => type}) do
    Logger.debug("Ignoring Stripe event #{type}")
    :ok
  end

  defp resolve_user(object) do
    user_id =
      object["client_reference_id"] || get_in(object, ["metadata", "user_id"])

    user_id && Accounts.get_user(user_id)
  end

  defp subscription_attrs(object) do
    price = get_in(object, ["items", "data", Access.at(0), "price"]) || %{}

    %{
      provider: "stripe",
      provider_customer_id: object["customer"],
      provider_subscription_id: object["id"] || object["subscription"],
      provider_price_id: price["id"],
      tier: tier_for_price(price["id"]),
      status: object["status"] || "active",
      amount_cents: price["unit_amount"],
      currency: price["currency"],
      interval: get_in(price, ["recurring", "interval"]),
      current_period_end: from_unix(object["current_period_end"]),
      cancel_at_period_end: object["cancel_at_period_end"] || false,
      trial_ends_at: from_unix(object["trial_end"])
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  # Reverse the configured price map to get from a Stripe price to a tier.
  defp tier_for_price(nil), do: "pro"

  defp tier_for_price(price_id) do
    Application.get_env(:superx, SuperX.Billing.Checkout, [])[:price_ids]
    |> Kernel.||(%{})
    |> Enum.find_value("pro", fn {{tier, _interval}, id} -> id == price_id && tier end)
  end

  defp from_unix(nil), do: nil

  defp from_unix(seconds) when is_integer(seconds) do
    DateTime.from_unix!(seconds) |> DateTime.truncate(:second)
  end
end
