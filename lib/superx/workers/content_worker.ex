defmodule SuperX.Workers.ContentWorker do
  @moduledoc """
  A repeatable writing brief for one connected X account.

  Schedules are stored in the owner's local time, just like publishing
  slots. This keeps “9am every day” stable through daylight saving and
  avoids making user-supplied cron syntax part of the product surface.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.{User, XAccount}

  @topic_sources ~w(products voice trends)
  @cadences ~w(daily weekly)
  @day_names ~w(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)

  schema "content_workers" do
    belongs_to :user, User
    belongs_to :x_account, XAccount

    field :name, :string
    field :topic_source, :string, default: "voice"
    field :product_context, :string

    field :batch_size, :integer, default: 3
    field :enabled, :boolean, default: true

    field :cadence, :string
    field :schedule_day, :integer
    field :schedule_time, :time

    field :last_run_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def topic_sources, do: @topic_sources
  def cadences, do: @cadences

  @doc false
  def changeset(worker, attrs) do
    worker
    |> cast(attrs, [
      :name,
      :topic_source,
      :product_context,
      :batch_size,
      :enabled,
      :cadence,
      :schedule_day,
      :schedule_time
    ])
    |> trim_text()
    |> validate_required([:name, :topic_source, :batch_size, :enabled])
    |> validate_length(:name, max: 80)
    |> validate_length(:product_context, max: 4000)
    |> validate_inclusion(:topic_source, @topic_sources)
    |> validate_inclusion(:cadence, @cadences)
    |> validate_number(:batch_size, greater_than_or_equal_to: 1, less_than_or_equal_to: 20)
    |> normalise_schedule()
    |> validate_product_context()
    |> validate_schedule()
    |> check_constraint(:topic_source, name: :content_workers_topic_source)
    |> check_constraint(:batch_size, name: :content_workers_batch_size)
    |> check_constraint(:product_context, name: :content_workers_product_context)
    |> check_constraint(:cadence, name: :content_workers_schedule)
  end

  defp trim_text(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> update_change(:product_context, &String.trim/1)
  end

  defp normalise_schedule(changeset) do
    case get_field(changeset, :cadence) do
      nil -> changeset |> put_change(:schedule_day, nil) |> put_change(:schedule_time, nil)
      "daily" -> put_change(changeset, :schedule_day, nil)
      _weekly -> changeset
    end
  end

  defp validate_product_context(changeset) do
    if get_field(changeset, :topic_source) == "products" do
      validate_required(changeset, [:product_context])
    else
      changeset
    end
  end

  defp validate_schedule(changeset) do
    case get_field(changeset, :cadence) do
      nil ->
        changeset

      "daily" ->
        validate_required(changeset, [:schedule_time])

      "weekly" ->
        changeset
        |> validate_required([:schedule_day, :schedule_time])
        |> validate_inclusion(:schedule_day, 0..6)

      _invalid ->
        changeset
    end
  end

  @doc "The human label used by both worker forms and schedules."
  def topic_source_label("products"), do: "Your products (what you are building)"
  def topic_source_label("voice"), do: "Your voice (how you write on X)"
  def topic_source_label("trends"), do: "Niche trends (what's moving today)"

  @doc "Human day name for a weekly worker."
  def day_name(day) when is_integer(day), do: Enum.at(@day_names, day)
end
