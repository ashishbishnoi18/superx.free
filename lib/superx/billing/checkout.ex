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
  alias SuperX.Teams

  @api "https://api.stripe.com/v1"

  @doc "Whether Stripe keys and price ids are present."
  def configured? do
    is_binary(secret_key()) and secret_key() != "" and map_size(price_ids()) > 0
  end

  @doc "Whether one plan can be checked out with its present seat count."
  def configured_for?(tier, interval, seat_count) do
    configured?() and Map.has_key?(price_ids(), {tier, to_string(interval)}) and
      (seat_count == 0 or Map.has_key?(seat_price_ids(), {tier, to_string(interval)}))
  end

  @doc """
  Creates a Checkout session and returns its URL.

  Reuses the Stripe customer if the user has one, so a second
  subscription doesn't fragment their billing history.
  """
  def create_session(%User{} = user, tier, interval) do
    seat_count = Billing.seat_count(user)

    with :ok <- billing_account(user),
         true <- configured?() || {:error, :not_configured},
         {:ok, price_id} <- price_id(tier, interval),
         {:ok, seat_price_id} <- seat_price_id(tier, interval, seat_count) do
      params =
        %{
          "mode" => "subscription",
          "line_items[0][price]" => price_id,
          "line_items[0][quantity]" => "1",
          "success_url" => absolute(~p"/upgrade?checkout=success"),
          "cancel_url" => absolute(~p"/upgrade?checkout=cancelled"),
          "client_reference_id" => user.id,
          "subscription_data[metadata][user_id]" => user.id,
          "subscription_data[metadata][seat_count]" => to_string(seat_count),
          "allow_promotion_codes" => "true"
        }
        |> put_customer(user)
        |> put_seats(seat_price_id, seat_count)

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

  defp billing_account(user) do
    if Teams.member?(user), do: {:error, :team_member}, else: :ok
  end

  @doc "A billing portal URL for an existing customer."
  def portal_url(%User{} = user) do
    if Teams.member?(user) do
      {:error, :team_member}
    else
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

  defp seat_price_id(_tier, _interval, 0), do: {:ok, nil}

  defp seat_price_id(tier, interval, _seat_count) do
    case Map.get(seat_price_ids(), {tier, to_string(interval)}) do
      nil -> {:error, {:no_seat_price_for, tier, interval}}
      id -> {:ok, id}
    end
  end

  defp put_seats(params, nil, 0), do: params

  defp put_seats(params, seat_price_id, seat_count) do
    params
    |> Map.put("line_items[1][price]", seat_price_id)
    |> Map.put("line_items[1][quantity]", to_string(seat_count))
  end

  # Configured as STRIPE_PRICE_PRO_MONTH, STRIPE_PRICE_ULTRA_YEAR, etc.
  defp price_ids do
    Application.get_env(:superx, __MODULE__, [])[:price_ids] || %{}
  end

  # Checkout sends the current member count as a second recurring line item.
  # The configured Stripe prices must carry the 2/11/51 volume tiers; this app
  # does not invent coupons. The catalogue and automatic changes to an already
  # live subscription have not been exercised against Stripe, so membership
  # changes are shown here but are not claimed to be synchronised mid-cycle.
  defp seat_price_ids do
    Application.get_env(:superx, __MODULE__, [])[:seat_price_ids] || %{}
  end

  defp secret_key do
    Application.get_env(:superx, SuperX.Billing, [])[:stripe_secret_key]
  end

  defp post(path, params) do
    req =
      Req.new(
        [
          url: @api <> path,
          form: params,
          auth: {:basic, "#{secret_key()}:"},
          receive_timeout: 20_000,
          retry: :transient,
          max_retries: 2
        ] ++ test_plug()
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

  defp test_plug do
    case Application.get_env(:superx, :stripe_plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end

  defp absolute(path), do: SuperXWeb.Endpoint.url() <> path
end
