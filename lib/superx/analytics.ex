defmodule SuperX.Analytics do
  @moduledoc """
  Daily account metrics and the aggregates the dashboard reads.

  Snapshots store absolute totals; growth is derived at read time by
  differencing the endpoints of a range. That keeps a missed collection
  day from corrupting every later number.
  """

  import Ecto.Query

  alias SuperX.Accounts.XAccount
  alias SuperX.Analytics.{HistoryImport, Share, Snapshot}
  alias SuperX.Content.Post
  alias SuperX.Repo

  @doc "Upserts the snapshot for one account on one date."
  def record_snapshot(%XAccount{} = account, %Date{} = date, metrics) do
    attrs =
      metrics
      |> Map.put(:x_account_id, account.id)
      |> Map.put(:date, date)
      |> Map.put(:source, "collected")

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
    summary(account, from, to)
  end

  @doc "Headline figures across a fixed inclusive window."
  def summary(%XAccount{} = account, %Date{} = from, %Date{} = to) do
    snapshots = list_snapshots(account, from, to)

    first = List.first(snapshots)
    last = List.last(snapshots)
    post_values = snapshots |> Enum.map(& &1.posts) |> Enum.reject(&is_nil/1)
    expected = Date.diff(to, from) + 1
    recorded = length(snapshots)

    %{
      followers: (last && last.followers) || account.followers_count,
      followers_change: delta(first, last, :followers),
      follower_change_available?: recorded >= 2,
      posts: total_delta(snapshots, :posts),
      posts_change_available?: length(post_values) >= 2,
      impressions: sum(snapshots, :impressions),
      engagements: sum(snapshots, :engagements),
      likes: sum(snapshots, :likes),
      replies: sum(snapshots, :replies),
      reposts: sum(snapshots, :reposts),
      coverage: %{expected: expected, recorded: recorded, missing: max(expected - recorded, 0)},
      series: Enum.map(snapshots, &Map.take(&1, [:date, :followers, :impressions, :engagements]))
    }
  end

  @doc "Dates represented by one of the dashboard's trailing windows."
  def date_window(days) when days in [7, 30, 90] do
    to = Date.utc_today()
    {Date.add(to, -days), to}
  end

  @doc "Imports a user-downloaded X analytics export."
  def import_history(%XAccount{} = account, csv), do: HistoryImport.run(account, csv)

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

  @doc """
  The account's own published posts, most recent first.

  Per-post engagement needs X's paid analytics tier, so ordering is by
  recency rather than performance until those figures exist — claiming to
  rank by engagement while sorting by date would be a lie the UI tells.
  """
  def recent_posts(%XAccount{} = account, limit \\ 5) do
    Post
    |> where([p], p.x_account_id == ^account.id and p.status == "posted")
    |> order_by(desc: :published_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Published posts ranked by their estimated share of a day's follower gain."
  def follower_gain_posts(%XAccount{} = account, %Date{} = from, %Date{} = to, limit \\ 5) do
    snapshots = list_snapshots(account, from, Date.add(to, 1))
    posts_by_date = published_posts_by_date(account, from, to)

    snapshots
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [previous, current] ->
      posts = Map.get(posts_by_date, previous.date, [])
      gain = current.followers - previous.followers

      # A daily total cannot identify which post caused a follow. Only
      # adjacent UTC snapshots qualify, and their positive net change is
      # divided evenly across posts published between them so the estimate
      # never multiplies one gain when several posts were published.
      if Date.diff(current.date, previous.date) == 1 and gain > 0 and posts != [] do
        estimate = gain / length(posts)
        Enum.map(posts, &%{post: &1, estimated_followers: estimate})
      else
        []
      end
    end)
    |> Enum.sort(fn left, right ->
      left.estimated_followers > right.estimated_followers or
        (left.estimated_followers == right.estimated_followers and
           DateTime.after?(left.post.published_at, right.post.published_at))
    end)
    |> Enum.take(limit)
  end

  @doc "Creates or replaces the account's public summary with a fresh capability URL."
  def create_share(%XAccount{} = account, %Date{} = from, %Date{} = to) do
    attrs = %{
      x_account_id: account.id,
      token: share_token(),
      from_date: from,
      to_date: to,
      revoked_at: nil
    }

    case Repo.get_by(Share, x_account_id: account.id) do
      nil -> %Share{} |> Share.changeset(attrs) |> Repo.insert()
      share -> share |> Share.changeset(attrs) |> Repo.update()
    end
  end

  @doc "The account's active public summary, if it has one."
  def get_share(%XAccount{} = account) do
    Share
    |> where([s], s.x_account_id == ^account.id and is_nil(s.revoked_at))
    |> Repo.one()
  end

  @doc "Revokes an account's public summary without reusing its old token."
  def revoke_share(%XAccount{} = account) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Share
    |> where([s], s.x_account_id == ^account.id and is_nil(s.revoked_at))
    |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    :ok
  end

  @doc "Looks up the deliberately small payload exposed by a public capability URL."
  def public_share(token) when is_binary(token) do
    Share
    |> where([s], s.token == ^token and is_nil(s.revoked_at))
    |> preload(:x_account)
    |> Repo.one()
    |> case do
      nil -> nil
      share -> public_payload(share)
    end
  end

  defp public_payload(%Share{} = share) do
    account = share.x_account

    summary =
      account
      |> summary(share.from_date, share.to_date)
      |> Map.take([:followers, :followers_change, :posts, :impressions, :engagements, :series])
      |> Map.update!(:series, fn series ->
        Enum.map(series, &Map.take(&1, [:date, :followers]))
      end)

    %{
      account: %{display_name: account.display_name, handle: account.handle},
      from_date: share.from_date,
      to_date: share.to_date,
      summary: summary
    }
  end

  defp published_posts_by_date(account, from, to) do
    from_at = DateTime.new!(from, ~T[00:00:00], "Etc/UTC")
    until_at = DateTime.new!(Date.add(to, 1), ~T[00:00:00], "Etc/UTC")

    Post
    |> where([p], p.x_account_id == ^account.id and p.status == "posted")
    |> where([p], p.published_at >= ^from_at and p.published_at < ^until_at)
    |> order_by(desc: :published_at)
    |> Repo.all()
    |> Enum.group_by(&DateTime.to_date(&1.published_at))
  end

  defp share_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp sum(snapshots, key), do: Enum.reduce(snapshots, 0, &(Map.fetch!(&1, key) + &2))

  defp delta(nil, _last, _key), do: 0
  defp delta(_first, nil, _key), do: 0
  defp delta(%{followers: nil}, _last, :followers), do: 0
  defp delta(_first, %{followers: nil}, :followers), do: 0
  defp delta(first, last, key), do: Map.fetch!(last, key) - Map.fetch!(first, key)

  defp total_delta(snapshots, key) do
    values = snapshots |> Enum.map(&Map.fetch!(&1, key)) |> Enum.reject(&is_nil/1)

    case values do
      [] -> 0
      [_one] -> 0
      values -> List.last(values) - List.first(values)
    end
  end

  defp date_to_datetime(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
end
