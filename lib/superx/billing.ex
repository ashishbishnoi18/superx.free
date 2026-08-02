defmodule SuperX.Billing do
  @moduledoc """
  Plans, subscriptions, quotas, and the credit ledger.

  Spending is deliberately pessimistic: a quota is claimed *before* the
  expensive work runs, and refunded if that work fails. The alternative —
  charging on success — lets a user fire unlimited concurrent requests
  before any of them settle.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SuperX.Accounts.User
  alias SuperX.Billing.{CreditEntry, Plan, Quota, Subscription}
  alias SuperX.Repo

  # --- Subscriptions -------------------------------------------------------

  def get_subscription(%User{} = user) do
    Repo.get_by(Subscription, user_id: user.id)
  end

  @doc "Every user has a subscription row; free users included."
  def ensure_subscription(%User{} = user) do
    case get_subscription(user) do
      nil ->
        %Subscription{}
        |> Subscription.changeset(%{user_id: user.id, tier: "free", status: "active"})
        |> Repo.insert()

      subscription ->
        {:ok, subscription}
    end
  end

  def upsert_subscription(%User{} = user, attrs) do
    case get_subscription(user) do
      nil -> %Subscription{} |> Subscription.changeset(Map.put(attrs, :user_id, user.id))
      sub -> Subscription.changeset(sub, attrs)
    end
    |> Repo.insert_or_update()
  end

  @doc """
  The user's current tier, defaulting to free.

  Always reads both membership and subscription fresh rather than trusting
  preloaded associations: a removed seat or plan change arriving by webhook
  must take effect for a session loaded before the change. A member resolves
  exactly one owner hop; product data and quota rows still belong to the member.
  """
  def tier(%User{} = user) do
    case entitlement_user(user) do
      nil -> default_tier()
      entitlement_user -> subscription_tier(entitlement_user)
    end
  end

  defp entitlement_user(%User{} = user) do
    case Repo.get(User, user.id) do
      %User{team_owner_id: nil} = user ->
        user

      %User{team_owner_id: owner_id} ->
        case Repo.get(User, owner_id) do
          %User{team_owner_id: nil} = owner -> owner
          _ -> nil
        end

      nil ->
        nil
    end
  end

  defp subscription_tier(user) do
    case get_subscription(user) do
      nil -> default_tier()
      sub -> effective_tier(sub)
    end
  end

  # A cancelled or unpaid plan silently drops to the default tier rather
  # than erroring, so the app keeps working with reduced allowances.
  defp effective_tier(%Subscription{} = sub) do
    if Subscription.entitled?(sub), do: sub.tier, else: default_tier()
  end

  @doc """
  The tier granted to users without a paid subscription.

  Defaults to `free`, which is right for a multi-tenant deployment. A
  self-hosted instance paying its own LLM bill has no reason to cap
  itself, so `SUPERX_DEFAULT_TIER=ultra` lifts every limit.
  """
  def default_tier do
    Application.get_env(:superx, :default_tier, "free")
  end

  @doc "Whether this instance grants paid limits without payment."
  def open_instance?, do: default_tier() != "free"

  # --- Seats ---------------------------------------------------------------

  @doc "The number of members billed under an owner's subscription."
  def seat_count(%User{} = owner) do
    User
    |> where(team_owner_id: ^owner.id)
    |> select(count())
    |> Repo.one()
  end

  @doc "The volume reduction applied to every member seat."
  def seat_discount_percent(count) when is_integer(count) and count >= 0 do
    cond do
      count >= 51 -> 35
      count >= 11 -> 30
      count >= 2 -> 25
      true -> 0
    end
  end

  @doc "A seat estimate for one tier and billing interval, in cents."
  def seat_pricing(tier, interval, count)
      when is_binary(tier) and interval in [:month, :year] and is_integer(count) and count >= 0 do
    discount_percent = seat_discount_percent(count)
    base_cents = Plan.price(tier, interval)
    unit_cents = div(base_cents * (100 - discount_percent) + 50, 100)

    %{
      count: count,
      discount_percent: discount_percent,
      unit_cents: unit_cents,
      total_cents: unit_cents * count
    }
  end

  # --- Quotas --------------------------------------------------------------

  @doc """
  Returns the live quota for a key, rolling the window and re-reading the
  plan limit if the previous window has expired.
  """
  def get_quota(%User{} = user, key) when is_binary(key) do
    get_quota(user, key, tier(user))
  end

  # Takes the tier explicitly so a caller reading several quotas at once
  # resolves the subscription once rather than per key.
  defp get_quota(%User{} = user, key, tier) when is_binary(key) do
    limit = Plan.limit(tier, key)

    case Repo.get_by(Quota, user_id: user.id, key: key) do
      nil ->
        create_quota(user, key, limit)

      quota ->
        cond do
          Quota.expired?(quota) -> roll_window(quota, limit)
          quota.limit != limit -> quota |> Quota.changeset(%{limit: limit}) |> Repo.update!()
          true -> quota
        end
    end
  end

  @doc "All quotas for the quota meter in the sidebar and upgrade page."
  def quota_snapshot(%User{} = user) do
    tier = tier(user)

    Quota.keys()
    |> Map.new(fn key ->
      quota = get_quota(user, key, tier)

      {key,
       %{
         used: quota.used,
         limit: quota.limit,
         remaining: Quota.remaining(quota),
         resets_at: quota.window_end
       }}
    end)
    # Carried on an atom key so it can't collide with a quota name. The
    # tier is already resolved here, and anything rendering the snapshot
    # would otherwise re-query to label it.
    |> Map.put(:tier, tier)
  end

  defp create_quota(%User{} = user, key, limit) do
    {window_start, window_end} = Quota.window_for(key)

    %Quota{}
    |> Quota.changeset(%{
      user_id: user.id,
      key: key,
      used: 0,
      limit: limit,
      window_start: window_start,
      window_end: window_end
    })
    |> Repo.insert!(
      on_conflict: [set: [updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]],
      conflict_target: [:user_id, :key],
      returning: true
    )
  end

  defp roll_window(%Quota{} = quota, limit) do
    {window_start, window_end} = Quota.window_for(quota.key)

    quota
    |> Quota.changeset(%{
      used: 0,
      limit: limit,
      window_start: window_start,
      window_end: window_end
    })
    |> Repo.update!()
  end

  @doc """
  Claims `amount` units of a quota, failing if it would exceed the limit.

  The check and the increment happen in one `UPDATE ... WHERE used +
  amount <= limit`, so concurrent callers cannot both pass a
  read-then-write race.
  """
  @spec claim(User.t(), binary(), pos_integer()) ::
          {:ok, Quota.t()} | {:error, :quota_exceeded, map()}
  def claim(%User{} = user, key, amount \\ 1) when amount > 0 do
    # Ensures the row exists and the window is current before we race on it.
    quota = get_quota(user, key)

    query =
      from(q in Quota,
        where: q.id == ^quota.id and q.used + ^amount <= q.limit,
        select: q
      )

    case Repo.update_all(query, inc: [used: amount]) do
      {1, [updated]} ->
        {:ok, updated}

      {0, _} ->
        {:error, :quota_exceeded,
         %{key: key, used: quota.used, limit: quota.limit, resets_at: quota.window_end}}
    end
  end

  @doc """
  Returns `amount` units to a quota. Used when the work a claim paid for
  failed, so the user isn't billed for our error.
  """
  def release(%User{} = user, key, amount \\ 1) when amount > 0 do
    from(q in Quota, where: q.user_id == ^user.id and q.key == ^key)
    |> Repo.update_all(inc: [used: -amount])

    :ok
  end

  # --- Credits -------------------------------------------------------------

  @doc "Current credit balance, derived from the credits_month quota."
  def credit_balance(%User{} = user) do
    user |> get_quota("credits_month") |> Quota.remaining()
  end

  @doc """
  Spends credits and writes a ledger entry in one transaction.

  Returns `{:error, :quota_exceeded, details}` when the user is out,
  which callers surface as an upgrade prompt rather than a crash.
  """
  def spend_credits(%User{} = user, amount, reason, opts \\ []) when amount > 0 do
    Multi.new()
    |> Multi.run(:claim, fn _repo, _changes ->
      case claim(user, "credits_month", amount) do
        {:ok, quota} -> {:ok, quota}
        {:error, :quota_exceeded, details} -> {:error, details}
      end
    end)
    |> Multi.insert(:entry, fn %{claim: quota} ->
      CreditEntry.changeset(%CreditEntry{}, %{
        user_id: user.id,
        delta: -amount,
        balance_after: Quota.remaining(quota),
        reason: reason,
        ref_type: opts[:ref_type],
        ref_id: opts[:ref_id],
        metadata: opts[:metadata] || %{}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{claim: quota}} -> {:ok, Quota.remaining(quota)}
      {:error, :claim, details, _} -> {:error, :quota_exceeded, details}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc "Returns credits after failed work, with an audit trail."
  def refund_credits(%User{} = user, amount, opts \\ []) when amount > 0 do
    release(user, "credits_month", amount)
    balance = credit_balance(user)

    %CreditEntry{}
    |> CreditEntry.changeset(%{
      user_id: user.id,
      delta: amount,
      balance_after: balance,
      reason: "refund",
      ref_type: opts[:ref_type],
      ref_id: opts[:ref_id],
      metadata: opts[:metadata] || %{}
    })
    |> Repo.insert()
  end

  def list_credit_entries(%User{} = user, limit \\ 50) do
    CreditEntry
    |> where(user_id: ^user.id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  # --- Provisioning --------------------------------------------------------

  @doc "Gives a brand-new user a free plan and zeroed quota windows."
  def provision(%User{} = user) do
    {:ok, subscription} = ensure_subscription(user)
    Enum.each(Quota.keys(), &get_quota(user, &1))
    {:ok, subscription}
  end

  @doc "Whether the user may connect another X account on their tier."
  def can_connect_account?(%User{} = user, current_count) do
    current_count < Plan.limit(tier(user), :x_accounts)
  end

  # --- Stripe ---------------------------------------------------------------

  # There is one paid plan, so paying lifts every limit rather than buying a
  # place in a ladder. The two prices differ in whose API keys get used, not
  # in what the software will do.
  @paid_tier "ultra"

  @doc """
  Applies an already-verified Stripe event.

  Unknown event types succeed rather than error: Stripe retries anything that
  does not return 2xx, and an endpoint subscribed to more types than it
  handles would otherwise retry those forever.
  """
  def apply_stripe_event(%{"type" => "checkout.session.completed", "data" => %{"object" => obj}}) do
    with %User{} = user <- user_from_stripe(obj) do
      upsert_subscription(user, %{
        provider: "stripe",
        provider_customer_id: obj["customer"],
        provider_subscription_id: obj["subscription"],
        status: "active",
        tier: @paid_tier
      })
    else
      _unknown -> {:ok, :ignored}
    end
  end

  def apply_stripe_event(%{"type" => "customer.subscription." <> _, "data" => %{"object" => obj}}) do
    with %User{} = user <- user_from_stripe(obj) do
      status = stripe_status(obj["status"])

      upsert_subscription(user, %{
        provider: "stripe",
        provider_customer_id: obj["customer"],
        provider_subscription_id: obj["id"],
        provider_price_id: get_in(obj, ["items", "data", Access.at(0), "price", "id"]),
        amount_cents: get_in(obj, ["items", "data", Access.at(0), "price", "unit_amount"]),
        currency: get_in(obj, ["items", "data", Access.at(0), "price", "currency"]),
        interval: get_in(obj, ["items", "data", Access.at(0), "price", "recurring", "interval"]),
        status: status,
        tier: if(status in ~w(active trialing past_due), do: @paid_tier, else: default_tier()),
        current_period_end: unix_to_datetime(obj["current_period_end"]),
        cancel_at_period_end: obj["cancel_at_period_end"] == true,
        canceled_at: unix_to_datetime(obj["canceled_at"])
      })
    else
      _unknown -> {:ok, :ignored}
    end
  end

  def apply_stripe_event(_event), do: {:ok, :ignored}

  # The id travels in metadata we set at checkout, so a forged customer id
  # cannot move somebody else's subscription. Falling back to the stored
  # customer id covers events Stripe raises without our metadata, such as a
  # cancellation made from the portal.
  defp user_from_stripe(object) do
    id = object["client_reference_id"] || get_in(object, ["metadata", "user_id"])

    with nil <- user_by_id(id),
         customer when is_binary(customer) <- object["customer"],
         %Subscription{user_id: user_id} <-
           Repo.get_by(Subscription, provider_customer_id: customer) do
      Repo.get(User, user_id)
    end
  end

  defp user_by_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(User, uuid)
      :error -> nil
    end
  end

  defp user_by_id(_id), do: nil

  # Stripe's `unpaid` and `incomplete_expired` have no row-level equivalent
  # here; both mean the same thing to this app as a cancellation.
  defp stripe_status("trialing"), do: "trialing"
  defp stripe_status("active"), do: "active"
  defp stripe_status("past_due"), do: "past_due"
  defp stripe_status("paused"), do: "paused"
  defp stripe_status(_ended), do: "canceled"

  defp unix_to_datetime(seconds) when is_integer(seconds) do
    seconds |> DateTime.from_unix!() |> DateTime.truncate(:second)
  end

  defp unix_to_datetime(_value), do: nil
end
