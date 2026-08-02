defmodule SuperX.Billing.Quota do
  @moduledoc """
  A usage counter for one metered thing over one time window.

  The row is the fast path: spending checks and increments happen here in
  a single statement. `SuperX.Billing.CreditEntry` keeps the audit trail.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.User

  @keys ~w(credits_month posts_month replies_day leads_day)

  schema "quotas" do
    belongs_to :user, User

    field :key, :string
    field :used, :integer, default: 0
    field :limit, :integer, default: 0
    field :window_start, :utc_datetime
    field :window_end, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def keys, do: @keys

  @doc false
  def changeset(quota, attrs) do
    quota
    |> cast(attrs, [:user_id, :key, :used, :limit, :window_start, :window_end])
    |> validate_required([:user_id, :key, :window_start, :window_end])
    |> validate_inclusion(:key, @keys)
    |> validate_number(:used, greater_than_or_equal_to: 0)
    |> unique_constraint([:user_id, :key])
  end

  @doc "Units still available in the current window."
  def remaining(%__MODULE__{used: used, limit: limit}), do: max(limit - used, 0)

  @doc "Whether the window has rolled past its end."
  def expired?(%__MODULE__{window_end: window_end}, now \\ DateTime.utc_now()) do
    DateTime.compare(now, window_end) != :lt
  end

  @doc """
  The window bounds for a quota key, anchored on `now`.

  Monthly keys run for 30 days from when the window opened rather than
  on calendar months, so a user who subscribes on the 31st isn't
  short-changed in February.
  """
  def window_for(key, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    seconds =
      case key do
        "credits_month" -> 30 * 24 * 3600
        "posts_month" -> 30 * 24 * 3600
        _daily -> 24 * 3600
      end

    {now, DateTime.add(now, seconds, :second)}
  end
end
