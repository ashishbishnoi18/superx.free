defmodule SuperX.Workers do
  @moduledoc """
  Configurable content generators and their local-time schedules.

  The context owns tenancy and cadence decisions; the Oban workers only
  dispatch and execute batches. This keeps user-facing schedules as data
  that can be validated and displayed, rather than opaque cron strings.
  """

  import Ecto.Query

  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Repo
  alias SuperX.Workers.ContentWorker
  alias SuperX.Workers.RunContentWorker

  def list_content_workers(%XAccount{} = account) do
    ContentWorker
    |> where(x_account_id: ^account.id)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  def get_content_worker(%User{} = user, %XAccount{} = account, id) do
    Repo.get_by(ContentWorker, id: id, user_id: user.id, x_account_id: account.id)
  end

  def fetch_content_worker(id) do
    case Repo.get(ContentWorker, id) do
      nil -> nil
      worker -> Repo.preload(worker, [:user, :x_account])
    end
  end

  def configured_for_account?(%XAccount{} = account) do
    ContentWorker
    |> where(x_account_id: ^account.id)
    |> Repo.exists?()
  end

  def create_content_worker(
        %User{id: user_id},
        %XAccount{user_id: user_id} = account,
        attrs
      ) do
    %ContentWorker{user_id: user_id, x_account_id: account.id}
    |> ContentWorker.changeset(attrs)
    |> Repo.insert()
  end

  def create_content_worker(%User{}, %XAccount{}, _attrs), do: {:error, :not_found}

  def update_content_worker(%ContentWorker{} = worker, attrs) do
    worker |> ContentWorker.changeset(attrs) |> Repo.update()
  end

  def change_content_worker(%ContentWorker{} = worker, attrs \\ %{}) do
    ContentWorker.changeset(worker, attrs)
  end

  def toggle_content_worker(%User{} = user, %XAccount{} = account, id) do
    case get_content_worker(user, account, id) do
      nil -> {:error, :not_found}
      worker -> update_content_worker(worker, %{enabled: not worker.enabled})
    end
  end

  def enqueue(%ContentWorker{} = worker) do
    %{content_worker_id: worker.id}
    |> RunContentWorker.new()
    |> Oban.insert()
  end

  @doc "Workers whose latest local-time occurrence has not run yet."
  def list_due_content_workers(now \\ DateTime.utc_now()) do
    ContentWorker
    |> where([w], w.enabled and not is_nil(w.cadence))
    |> preload([:user, :x_account])
    |> Repo.all()
    |> Enum.filter(&due?(&1, now))
  end

  @doc false
  def due?(%ContentWorker{enabled: true, user: %User{} = user} = worker, %DateTime{} = now) do
    with %DateTime{} = occurrence <- latest_occurrence(worker, user.timezone, now) do
      baseline = worker.last_run_at || worker.inserted_at
      DateTime.compare(occurrence, baseline) == :gt
    else
      _ -> false
    end
  end

  def due?(_worker, _now), do: false

  @doc false
  def latest_occurrence(
        %ContentWorker{cadence: cadence, schedule_time: %Time{}} = worker,
        timezone,
        %DateTime{} = now
      )
      when cadence in ["daily", "weekly"] do
    with {:ok, local_now} <- DateTime.shift_zone(now, timezone, Tz.TimeZoneDatabase) do
      lookback = if cadence == "daily", do: 2, else: 8

      0..lookback
      |> Enum.find_value(fn days_ago ->
        date = local_now |> DateTime.to_date() |> Date.add(-days_ago)

        if scheduled_on?(worker, date) do
          occurrence_on(date, worker.schedule_time, timezone, local_now)
        end
      end)
    else
      _ -> nil
    end
  end

  def latest_occurrence(_worker, _timezone, _now), do: nil

  defp scheduled_on?(%ContentWorker{cadence: "daily"}, _date), do: true

  defp scheduled_on?(%ContentWorker{cadence: "weekly", schedule_day: day}, date) do
    Date.day_of_week(date, :sunday) - 1 == day
  end

  defp occurrence_on(date, time, timezone, local_now) do
    with {:ok, local} <- DateTime.new(date, time, timezone, Tz.TimeZoneDatabase),
         comparison when comparison in [:lt, :eq] <- DateTime.compare(local, local_now),
         {:ok, utc} <- DateTime.shift_zone(local, "Etc/UTC") do
      DateTime.truncate(utc, :second)
    else
      _ -> nil
    end
  end

  def record_run_started(%ContentWorker{} = worker, now \\ DateTime.utc_now()) do
    worker
    |> Ecto.Changeset.change(last_run_at: DateTime.truncate(now, :second))
    |> Repo.update()
  end
end
