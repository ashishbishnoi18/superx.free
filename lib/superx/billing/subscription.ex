defmodule SuperX.Billing.Subscription do
  @moduledoc """
  A user's plan. Every user has exactly one row; unpaid users sit on the
  `free` tier rather than having no subscription, so quota lookups never
  need a nil branch.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.User

  @tiers ~w(free pro advanced ultra)
  @statuses ~w(trialing active past_due canceled paused)

  schema "subscriptions" do
    belongs_to :user, User

    field :provider, :string, default: "stripe"
    field :provider_customer_id, :string
    field :provider_subscription_id, :string
    field :provider_price_id, :string

    field :tier, :string, default: "free"
    field :status, :string, default: "active"

    field :amount_cents, :integer
    field :currency, :string
    field :interval, :string

    field :trial_ends_at, :utc_datetime
    field :current_period_end, :utc_datetime
    field :cancel_at_period_end, :boolean, default: false
    field :canceled_at, :utc_datetime

    field :card_brand, :string
    field :card_last4, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :user_id,
      :provider,
      :provider_customer_id,
      :provider_subscription_id,
      :provider_price_id,
      :tier,
      :status,
      :amount_cents,
      :currency,
      :interval,
      :trial_ends_at,
      :current_period_end,
      :cancel_at_period_end,
      :canceled_at,
      :card_brand,
      :card_last4
    ])
    |> validate_required([:user_id, :tier, :status])
    |> validate_inclusion(:tier, @tiers)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:user_id)
    |> unique_constraint(:provider_subscription_id)
  end

  @doc """
  Whether the plan currently entitles the user to paid features. A
  past-due subscription still works until the period ends, which avoids
  cutting someone off over a transient card failure.
  """
  def entitled?(%__MODULE__{status: status, tier: tier})
      when tier != "free" and status in ~w(trialing active),
      do: true

  def entitled?(%__MODULE__{status: "past_due", tier: tier, current_period_end: nil})
      when tier != "free",
      do: true

  def entitled?(%__MODULE__{
        status: "past_due",
        tier: tier,
        current_period_end: current_period_end
      })
      when tier != "free" do
    DateTime.compare(current_period_end, DateTime.utc_now()) == :gt
  end

  def entitled?(_), do: false

  @doc "Human label for the plan badge in the sidebar."
  def label(%__MODULE__{tier: "free"}), do: "Free"
  def label(%__MODULE__{status: "trialing", tier: tier}), do: "#{String.capitalize(tier)} trial"
  def label(%__MODULE__{tier: tier}), do: String.capitalize(tier)
end
