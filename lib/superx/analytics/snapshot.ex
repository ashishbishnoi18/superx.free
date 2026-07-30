defmodule SuperX.Analytics.Snapshot do
  @moduledoc """
  One day of metrics for one account.

  Stored as absolute totals rather than deltas so a missed day leaves a
  gap instead of corrupting every subsequent figure; the dashboard
  derives day-over-day change at read time.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.XAccount

  schema "analytics_snapshots" do
    belongs_to :x_account, XAccount

    field :date, :date

    field :followers, :integer, default: 0
    field :following, :integer, default: 0
    field :posts, :integer, default: 0

    field :impressions, :integer, default: 0
    field :engagements, :integer, default: 0
    field :likes, :integer, default: 0
    field :replies, :integer, default: 0
    field :reposts, :integer, default: 0
    field :profile_clicks, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :x_account_id,
      :date,
      :followers,
      :following,
      :posts,
      :impressions,
      :engagements,
      :likes,
      :replies,
      :reposts,
      :profile_clicks
    ])
    |> validate_required([:x_account_id, :date])
    |> unique_constraint([:x_account_id, :date])
  end
end
