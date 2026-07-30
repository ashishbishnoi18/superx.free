defmodule SuperX.Content.ScheduleSlot do
  @moduledoc """
  A recurring weekly publishing slot, expressed in the user's local time.

  Slots are the scheduling primitive: the user defines when they want to
  post, and queued content fills the next open slot. Storing local time
  (rather than UTC) is deliberate — a 9am slot stays 9am across DST.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.XAccount

  schema "schedule_slots" do
    belongs_to :x_account, XAccount

    field :day_of_week, :integer
    field :time, :time
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(slot, attrs) do
    slot
    |> cast(attrs, [:x_account_id, :day_of_week, :time, :enabled])
    |> validate_required([:x_account_id, :day_of_week, :time])
    |> validate_inclusion(:day_of_week, 0..6)
    |> truncate_time()
    |> unique_constraint([:x_account_id, :day_of_week, :time],
      message: "already has a slot at this time"
    )
  end

  # Slots are minute-granular; the dispatcher ticks once a minute.
  defp truncate_time(changeset) do
    update_change(changeset, :time, fn
      %Time{} = time -> %{time | second: 0, microsecond: {0, 0}}
      other -> other
    end)
  end

  @doc """
  A sensible starting schedule for a new account: four posts a week at
  times that skew toward weekday mornings.
  """
  def defaults do
    [
      %{day_of_week: 1, time: ~T[10:00:00]},
      %{day_of_week: 2, time: ~T[13:00:00]},
      %{day_of_week: 3, time: ~T[09:00:00]},
      %{day_of_week: 4, time: ~T[11:00:00]}
    ]
  end

  @day_names ~w(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)

  @doc "Human day name for a slot."
  def day_name(%__MODULE__{day_of_week: dow}), do: Enum.at(@day_names, dow)
  def day_name(dow) when is_integer(dow), do: Enum.at(@day_names, dow)
end
