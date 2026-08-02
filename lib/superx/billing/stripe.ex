defmodule SuperX.Billing.Stripe do
  @moduledoc """
  The Stripe boundary: checkout, the customer portal, and webhook signatures.

  Only the hosted instance configures this. A self-hosted deployment leaves
  the keys unset, `configured?/0` stays false, and the whole billing surface
  disappears rather than showing a page that cannot take money.

  Stripe's API is form-encoded, not JSON, including nested keys like
  `line_items[0][price]`. Encoding is done here so callers pass plain maps.
  """

  require Logger

  @base "https://api.stripe.com/v1"

  @doc "Whether this instance can take payment at all."
  def configured?, do: is_binary(secret_key()) and secret_key() != ""

  @doc "The two prices this instance sells, in the order they should be shown."
  def prices do
    [
      %{
        id: price_id(:keys_included),
        key: "keys_included",
        name: "Keys included",
        cents: 900,
        blurb: "Everything runs on our API keys. Nothing to sign up for."
      },
      %{
        id: price_id(:byo),
        key: "byo",
        name: "Bring your own keys",
        cents: 500,
        blurb: "You supply the X and model keys. Cheaper, and your quota."
      }
    ]
    |> Enum.filter(&(is_binary(&1.id) and &1.id != ""))
  end

  def price_by_key(key), do: Enum.find(prices(), &(&1.key == key))

  @doc """
  Starts a hosted checkout for one price.

  The user id rides in `client_reference_id` so the webhook can find them
  without trusting anything the browser sends back.
  """
  def create_checkout_session(user, price_id, urls) do
    post("/checkout/sessions", %{
      "mode" => "subscription",
      "client_reference_id" => user.id,
      "customer_email" => user.email,
      "success_url" => urls.success,
      "cancel_url" => urls.cancel,
      "line_items[0][price]" => price_id,
      "line_items[0][quantity]" => 1,
      "subscription_data[metadata][user_id]" => user.id,
      "metadata[user_id]" => user.id
    })
  end

  @doc "A portal session so the user can cancel or change card without us."
  def create_portal_session(customer_id, return_url) do
    post("/billing_portal/sessions", %{
      "customer" => customer_id,
      "return_url" => return_url
    })
  end

  def get_subscription(subscription_id), do: get("/subscriptions/#{subscription_id}")

  @doc """
  Verifies a webhook signature and returns the decoded event.

  Compared in constant time, and the timestamp is checked so a captured
  request cannot be replayed later against this endpoint.
  """
  def verify_webhook(raw_body, signature_header, now \\ System.system_time(:second)) do
    with secret when is_binary(secret) and secret != "" <- webhook_secret(),
         {:ok, timestamp, signatures} <- parse_signature_header(signature_header),
         :ok <- check_timestamp(timestamp, now),
         expected <- sign(secret, "#{timestamp}.#{raw_body}"),
         true <- Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, expected)),
         {:ok, event} <- Jason.decode(raw_body) do
      {:ok, event}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_signature}
    end
  end

  defp parse_signature_header(header) when is_binary(header) do
    parts =
      header
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))

    timestamp =
      Enum.find_value(parts, fn
        ["t", value] -> value
        _ -> nil
      end)

    signatures = for ["v1", value] <- parts, do: value

    case {timestamp, signatures} do
      {t, [_ | _]} when is_binary(t) -> {:ok, t, signatures}
      _missing -> {:error, :invalid_signature}
    end
  end

  defp parse_signature_header(_header), do: {:error, :invalid_signature}

  # Stripe's own tolerance is five minutes. Beyond it a replayed body with a
  # still-valid signature would be accepted forever.
  defp check_timestamp(timestamp, now) do
    case Integer.parse(timestamp) do
      {seconds, ""} when abs(now - seconds) <= 300 -> :ok
      _stale -> {:error, :timestamp_out_of_tolerance}
    end
  end

  defp sign(secret, payload) do
    :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
  end

  defp get(path), do: request(:get, path, nil)
  defp post(path, params), do: request(:post, path, params)

  defp request(method, path, params) do
    if configured?() do
      options =
        [
          url: @base <> path,
          method: method,
          auth: {:basic, "#{secret_key()}:"},
          receive_timeout: 30_000,
          retry: :transient,
          max_retries: 2
        ] ++ body_option(params) ++ test_plug()

      case Req.request(Req.new(options)) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("Stripe #{method} #{path} returned #{status}: #{inspect(body)}")
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          Logger.warning("Stripe #{method} #{path} failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :not_configured}
    end
  end

  defp body_option(nil), do: []
  defp body_option(params), do: [form: params]

  defp test_plug do
    case Application.get_env(:superx, :stripe_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end

  defp config, do: Application.get_env(:superx, __MODULE__, [])
  defp secret_key, do: config()[:secret_key]
  def publishable_key, do: config()[:publishable_key]
  defp webhook_secret, do: config()[:webhook_secret]
  defp price_id(:keys_included), do: config()[:price_keys_included]
  defp price_id(:byo), do: config()[:price_byo]
end
