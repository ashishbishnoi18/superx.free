defmodule SuperX.Billing.Checkout do
  @moduledoc """
  Stripe Checkout and the customer portal.

  Talks to Stripe's REST API directly with Req rather than pulling in an
  SDK — three endpoints do not justify the dependency, and the form
  encoding is the only fiddly part.
  """

  use SuperXWeb, :verified_routes

  require Logger

  alias SuperX.Accounts.User
  alias SuperX.Billing
  alias SuperX.Billing.Subscription

  @api "https://api.stripe.com/v1"

  @doc "Whether Stripe keys and price ids are present."
  def configured? do
    is_binary(secret_key()) and secret_key() != "" and map_size(price_ids()) > 0
  end

  @doc """
  Creates a Checkout session and returns its URL.

  Reuses the Stripe customer if the user has one, so a second
  subscription doesn't fragment their billing history.
  """
  def create_session(%User{} = user, tier, interval) do
    with true <- configured?() || {:error, :not_configured},
         {:ok, price_id} <- price_id(tier, interval) do
      params =
        %{
          "mode" => "subscription",
          "line_items[0][price]" => price_id,
          "line_items[0][quantity]" => "1",
          "success_url" => absolute(~p"/upgrade?checkout=success"),
          "cancel_url" => absolute(~p"/upgrade?checkout=cancelled"),
          "client_reference_id" => user.id,
          "subscription_data[metadata][user_id]" => user.id,
          "allow_promotion_codes" => "true"
        }
        |> put_customer(user)

      case post("/checkout/sessions", params) do
        {:ok, %{"url" => url}} -> {:ok, url}
        {:ok, other} -> {:error, {:unexpected_response, other}}
        error -> error
      end
    else
      false -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "A billing portal URL for an existing customer."
  def portal_url(%User{} = user) do
    case Billing.get_subscription(user) do
      %Subscription{provider_customer_id: customer_id} when is_binary(customer_id) ->
        case post("/billing_portal/sessions", %{
               "customer" => customer_id,
               "return_url" => absolute(~p"/upgrade")
             }) do
          {:ok, %{"url" => url}} -> {:ok, url}
          error -> error
        end

      _ ->
        {:error, :no_customer}
    end
  end

  defp put_customer(params, %User{} = user) do
    case Billing.get_subscription(user) do
      %Subscription{provider_customer_id: id} when is_binary(id) ->
        Map.put(params, "customer", id)

      _ ->
        # Let Stripe create the customer; the webhook records the id.
        if user.email, do: Map.put(params, "customer_email", user.email), else: params
    end
  end

  defp price_id(tier, interval) do
    case Map.get(price_ids(), {tier, to_string(interval)}) do
      nil -> {:error, {:no_price_for, tier, interval}}
      id -> {:ok, id}
    end
  end

  # Configured as STRIPE_PRICE_PRO_MONTH, STRIPE_PRICE_ULTRA_YEAR, etc.
  defp price_ids do
    Application.get_env(:superx, __MODULE__, [])[:price_ids] || %{}
  end

  defp secret_key do
    Application.get_env(:superx, SuperX.Billing, [])[:stripe_secret_key]
  end

  defp post(path, params) do
    req =
      Req.new(
        url: @api <> path,
        form: params,
        auth: {:basic, "#{secret_key()}:"},
        receive_timeout: 20_000,
        retry: :transient,
        max_retries: 2
      )

    case Req.post(req) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Stripe #{path} returned #{status}: #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp absolute(path), do: SuperXWeb.Endpoint.url() <> path
end
