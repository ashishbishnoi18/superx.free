defmodule SuperX.Analytics do
  @moduledoc """
  Daily account metrics and the aggregates the dashboard reads.

  Snapshots store absolute totals; growth is derived at read time by
  differencing the endpoints of a range. That keeps a missed collection
  day from corrupting every later number.
  """

  import Ecto.Query

  alias SuperX.Accounts.XAccount
  alias SuperX.Analytics.Snapshot
  alias SuperX.Content.Post
  alias SuperX.Repo

  @doc "Upserts the snapshot for one account on one date."
  def record_snapshot(%XAccount{} = account, %Date{} = date, metrics) do
    attrs =
      metrics
      |> Map.put(:x_account_id, account.id)
      |> Map.put(:date, date)

    %Snapshot{}
    |> Snapshot.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at, :x_account_id, :date]},
      conflict_target: [:x_account_id, :date]
    )
  end

  @doc "Snapshots for an account across an inclusive date range, oldest first."
  def list_snapshots(%XAccount{} = account, %Date{} = from, %Date{} = to) do
    Snapshot
    |> where([s], s.x_account_id == ^account.id and s.date >= ^from and s.date <= ^to)
    |> order_by(asc: :date)
    |> Repo.all()
  end

  @doc """
  Headline figures for the dashboard over the last `days` days.

  `followers` and `posts` are stored as running totals, so the figures
  reported are the net change across the range — summing them would
  multiply the lifetime total by the number of days. The engagement
  columns are genuine per-day counters, so those are summed.
  """
  def summary(%XAccount{} = account, days \\ 30) do
    to = Date.utc_today()
    from = Date.add(to, -days)
    snapshots = list_snapshots(account, from, to)

    first = List.first(snapshots)
    last = List.last(snapshots)

    %{
      followers: (last && last.followers) || account.followers_count,
      followers_change: delta(first, last, :followers),
      posts: delta(first, last, :posts),
      impressions: sum(snapshots, :impressions),
      engagements: sum(snapshots, :engagements),
      likes: sum(snapshots, :likes),
      replies: sum(snapshots, :replies),
      reposts: sum(snapshots, :reposts),
      series: Enum.map(snapshots, &Map.take(&1, [:date, :followers, :impressions, :engagements]))
    }
  end

  @doc "The small figures Home shows without loading the whole dashboard."
  def today_summary(%XAccount{} = account) do
    today = Date.utc_today()

    case Repo.get_by(Snapshot, x_account_id: account.id, date: today) do
      nil -> %{followers: account.followers_count, impressions: 0, engagements: 0}
      snapshot -> Map.take(snapshot, [:followers, :impressions, :engagements])
    end
  end

  @doc """
  Publishing activity per day for the streak heatmap, as a
  `%{Date => count}` map over the trailing `days`.
  """
  def posting_activity(%XAccount{} = account, days \\ 365) do
    from = Date.utc_today() |> Date.add(-days) |> date_to_datetime()

    Post
    |> where([p], p.x_account_id == ^account.id)
    |> where([p], p.status == "posted" and p.published_at >= ^from)
    |> group_by([p], fragment("date(?)", p.published_at))
    |> select([p], {fragment("date(?)", p.published_at), count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Length of the current daily posting streak, counting back from today.

  Today not having a post yet doesn't break the streak — only a full
  empty day does.
  """
  def current_streak(%XAccount{} = account) do
    activity = posting_activity(account, 400)
    today = Date.utc_today()

    start = if Map.has_key?(activity, today), do: today, else: Date.add(today, -1)

    Stream.iterate(start, &Date.add(&1, -1))
    |> Enum.reduce_while(0, fn date, count ->
      if Map.has_key?(activity, date), do: {:cont, count + 1}, else: {:halt, count}
    end)
  end

  defp sum(snapshots, key), do: Enum.reduce(snapshots, 0, &(Map.fetch!(&1, key) + &2))

  defp delta(nil, _last, _key), do: 0
  defp delta(_first, nil, _key), do: 0
  defp delta(first, last, key), do: Map.fetch!(last, key) - Map.fetch!(first, key)

  defp date_to_datetime(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
end
