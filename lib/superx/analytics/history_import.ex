defmodule SuperX.Analytics.HistoryImport do
  @moduledoc """
  Imports X's user-downloaded daily analytics export without weakening the
  nightly collector as the source of truth.

  X has changed both headings and whether follower history is expressed as
  a total or as follows minus unfollows. Headers are matched by meaning and
  running totals are rebuilt only where an observed account total anchors a
  contiguous run; an attractive but ungrounded trend is worse than a gap.
  """

  import Ecto.Query

  alias SuperX.Accounts.XAccount
  alias SuperX.Analytics.Snapshot
  alias SuperX.Repo

  @aliases %{
    date: ~w(date day period time timestamp),
    followers: ~w(followers follower_count followers_count total_followers total_followers_count),
    following: ~w(following following_count follows_count total_following),
    total_posts: ~w(total_posts total_tweets post_count posts_count tweet_count tweets_count),
    daily_posts: ~w(posts tweets posts_published tweets_published),
    follower_change: ~w(follower_change followers_change net_followers net_follows follower_gain),
    new_followers:
      ~w(new_follower new_followers followers_gained follows_gained new_follows follows),
    unfollows: ~w(unfollows new_unfollows followers_lost lost_followers unfollowers),
    impressions: ~w(impressions post_impressions tweet_impressions tweets_impressions views),
    engagements: ~w(engagements total_engagements post_engagements tweet_engagements),
    likes: ~w(likes post_likes tweet_likes),
    replies: ~w(replies post_replies tweet_replies),
    reposts: ~w(reposts retweets post_reposts tweet_retweets),
    profile_clicks: ~w(profile_clicks profile_visits user_profile_clicks user_profile_visits)
  }

  @number_fields Map.keys(@aliases) -- [:date]
  @daily_metrics ~w(impressions engagements likes replies reposts profile_clicks)a

  @doc "Imports one CSV export and returns an exact account of every row."
  def run(%XAccount{} = account, csv) when is_binary(csv) do
    with {:ok, [headers | body]} <- parse_csv(csv),
         indexes <- index_headers(headers),
         :ok <- validate_headers(indexes) do
      {rows, invalid} = parse_rows(body, indexes)
      {rows, duplicates} = unique_rows(rows)
      rows = resolve_totals(account, rows)

      {ready, unresolved} =
        Enum.split_with(rows, &(is_integer(&1.followers) and &1.followers >= 0))

      {inserted, dates} = insert_rows(account, ready)

      {:ok,
       %{
         imported: inserted,
         imported_from: Enum.min(dates, fn -> nil end),
         imported_to: Enum.max(dates, fn -> nil end),
         recognised: recognised_metrics(indexes),
         skipped_existing: length(ready) - inserted,
         skipped_duplicate: duplicates,
         skipped_invalid: invalid + length(unresolved)
       }}
    else
      {:ok, []} -> {:error, :empty_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_headers(indexes) do
    cond do
      not Map.has_key?(indexes, :date) -> {:error, :missing_date}
      not follower_history?(indexes) -> {:error, :missing_followers}
      true -> :ok
    end
  end

  defp follower_history?(indexes) do
    Enum.any?(
      [:followers, :follower_change, :new_followers, :unfollows],
      &Map.has_key?(indexes, &1)
    )
  end

  defp index_headers(headers) do
    headers
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {header, index}, acc ->
      case canonical_header(header) do
        nil -> acc
        key -> Map.put_new(acc, key, index)
      end
    end)
  end

  defp canonical_header(header) do
    normalised =
      header
      |> String.trim_leading(<<0xEF, 0xBB, 0xBF>>)
      |> String.trim()
      |> String.downcase()
      |> String.replace("&", " and ")
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")

    Enum.find_value(@aliases, fn {key, aliases} -> if normalised in aliases, do: key end)
  end

  defp parse_rows(rows, indexes) do
    Enum.reduce(rows, {[], 0}, fn values, {parsed, invalid} ->
      case parse_row(values, indexes) do
        {:ok, row} -> {[row | parsed], invalid}
        {:error, _reason} -> {parsed, invalid + 1}
      end
    end)
    |> then(fn {parsed, invalid} -> {Enum.reverse(parsed), invalid} end)
  end

  defp parse_row(values, indexes) do
    with {:ok, date} <- values |> value(indexes[:date]) |> parse_date(),
         {:ok, numbers} <- parse_numbers(values, indexes) do
      follower_change =
        numbers[:follower_change] ||
          additions_minus_removals(numbers[:new_followers], numbers[:unfollows])

      {:ok,
       numbers
       |> Map.merge(%{
         date: date,
         followers: numbers[:followers],
         posts: numbers[:total_posts],
         follower_change: follower_change,
         post_change: numbers[:daily_posts]
       })}
    end
  end

  defp parse_numbers(values, indexes) do
    Enum.reduce_while(@number_fields, {:ok, %{}}, fn field, {:ok, numbers} ->
      case Map.fetch(indexes, field) do
        :error ->
          {:cont, {:ok, numbers}}

        {:ok, index} ->
          case parse_number(value(values, index)) do
            {:ok, nil} ->
              {:cont, {:ok, Map.put(numbers, field, nil)}}

            {:ok, number} when number >= 0 or field == :follower_change ->
              {:cont, {:ok, Map.put(numbers, field, number)}}

            _error ->
              {:halt, {:error, {:invalid_number, field}}}
          end
      end
    end)
  end

  defp additions_minus_removals(nil, nil), do: nil
  defp additions_minus_removals(additions, removals), do: (additions || 0) - (removals || 0)

  defp unique_rows(rows) do
    {by_date, duplicates} =
      Enum.reduce(rows, {%{}, 0}, fn row, {by_date, duplicates} ->
        if Map.has_key?(by_date, row.date) do
          {by_date, duplicates + 1}
        else
          {Map.put(by_date, row.date, row), duplicates}
        end
      end)

    {by_date |> Map.values() |> Enum.sort_by(& &1.date, Date), duplicates}
  end

  defp resolve_totals(_account, []), do: []

  defp resolve_totals(account, rows) do
    from = rows |> List.first() |> Map.fetch!(:date) |> Date.add(-1)
    to = rows |> List.last() |> Map.fetch!(:date) |> Date.add(1)

    anchors =
      Snapshot
      |> where([s], s.x_account_id == ^account.id and s.date >= ^from and s.date <= ^to)
      |> Repo.all()

    anchors = account_anchor(account) ++ anchors

    follower_totals = running_totals(rows, anchors, :followers, :follower_change)
    post_totals = running_totals(rows, anchors, :posts, :post_change)

    Enum.map(rows, fn row ->
      row
      |> Map.put(:followers, non_negative_total(follower_totals[row.date]))
      |> Map.put(:posts, non_negative_total(post_totals[row.date]))
    end)
  end

  defp running_totals(rows, anchors, total_key, change_key) do
    totals =
      Enum.reduce(rows, %{}, fn row, acc -> put_total(acc, row.date, row[total_key]) end)

    totals =
      Enum.reduce(anchors, totals, fn anchor, acc ->
        put_total(acc, anchor.date, Map.get(anchor, total_key))
      end)

    # The collector runs just after midnight, so a change labelled for D
    # connects the total at D to the total at D+1. Reversing that edge is
    # what keeps an imported gain beside the posts that preceded the next
    # collected snapshot instead of shifting attribution forward a day.
    totals =
      Enum.reduce(Enum.reverse(rows), totals, fn row, acc ->
        with total when is_integer(total) <- acc[Date.add(row.date, 1)],
             change when is_integer(change) <- row[change_key] do
          Map.put_new(acc, row.date, total - change)
        else
          _ -> acc
        end
      end)

    Enum.reduce(rows, totals, fn row, acc ->
      with total when is_integer(total) <- acc[row.date],
           change when is_integer(change) <- row[change_key] do
        Map.put_new(acc, Date.add(row.date, 1), total + change)
      else
        _ -> acc
      end
    end)
  end

  defp non_negative_total(total) when is_integer(total) and total >= 0, do: total
  defp non_negative_total(_total), do: nil

  defp account_anchor(%XAccount{last_synced_at: %DateTime{} = synced_at} = account) do
    date = DateTime.to_date(synced_at)

    if date == Date.utc_today() do
      [%{date: date, followers: account.followers_count, posts: account.posts_count}]
    else
      []
    end
  end

  defp account_anchor(%XAccount{}), do: []

  defp put_total(totals, _date, nil), do: totals
  defp put_total(totals, date, total), do: Map.put(totals, date, total)

  defp insert_rows(_account, []), do: {0, []}

  defp insert_rows(account, rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(rows, fn row ->
        %{
          id: Ecto.UUID.generate(),
          x_account_id: account.id,
          date: row.date,
          followers: row.followers,
          following: row[:following],
          posts: row.posts,
          impressions: metric(row, :impressions),
          engagements: metric(row, :engagements),
          likes: metric(row, :likes),
          replies: metric(row, :replies),
          reposts: metric(row, :reposts),
          profile_clicks: metric(row, :profile_clicks),
          source: "imported",
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, returned} =
      Repo.insert_all(Snapshot, entries,
        on_conflict: :nothing,
        conflict_target: [:x_account_id, :date],
        returning: [:date]
      )

    {count, Enum.map(returned, & &1.date)}
  end

  defp metric(row, key), do: max(row[key] || 0, 0)

  defp recognised_metrics(indexes) do
    []
    |> maybe_recognise(indexes, :followers, [
      :followers,
      :follower_change,
      :new_followers,
      :unfollows
    ])
    |> maybe_recognise(indexes, :posts, [:total_posts, :daily_posts])
    |> then(fn recognised ->
      Enum.reduce(@daily_metrics, recognised, fn metric, acc ->
        maybe_recognise(acc, indexes, metric, [metric])
      end)
    end)
  end

  defp maybe_recognise(recognised, indexes, label, fields) do
    if Enum.any?(fields, &Map.has_key?(indexes, &1)), do: recognised ++ [label], else: recognised
  end

  defp value(_values, nil), do: ""
  defp value(values, index), do: Enum.at(values, index, "") |> String.trim()

  defp parse_number(value) when value in ["", "-", "—"], do: {:ok, nil}

  defp parse_number(value) do
    value =
      value
      |> String.replace([",", " ", "\u00A0"], "")
      |> normalise_parentheses()

    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> parse_float(value)
    end
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, round(number)}
      _ -> {:error, :invalid_number}
    end
  end

  defp normalise_parentheses("(" <> rest) do
    if String.ends_with?(rest, ")"), do: "-" <> String.trim_trailing(rest, ")"), else: rest
  end

  defp normalise_parentheses(value), do: value

  defp parse_date(value) do
    cond do
      match?({:ok, _}, Date.from_iso8601(String.slice(value, 0, 10))) ->
        Date.from_iso8601(String.slice(value, 0, 10))

      captures = Regex.run(~r/^(\d{4})[\/-](\d{1,2})[\/-](\d{1,2})$/, value) ->
        date_from_parts(captures, [1, 2, 3])

      captures = Regex.run(~r/^(\d{1,2})[\/-](\d{1,2})[\/-](\d{4})$/, value) ->
        # X's downloadable dashboard uses US ordering when it localises the
        # ISO date; an ambiguous pair cannot be guessed from the row alone.
        date_from_parts(captures, [3, 1, 2])

      true ->
        {:error, :invalid_date}
    end
  end

  defp date_from_parts(captures, indexes) do
    [year, month, day] = Enum.map(indexes, &(captures |> Enum.at(&1) |> String.to_integer()))
    Date.new(year, month, day)
  end

  defp parse_csv(csv) do
    csv = csv |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

    case parse_bytes(csv, :field, [], [], []) do
      {:ok, rows} ->
        rows = Enum.reject(rows, &Enum.all?(&1, fn value -> String.trim(value) == "" end))
        {:ok, rows}

      error ->
        error
    end
  end

  defp parse_bytes(<<>>, :quoted, _field, _row, _rows), do: {:error, :malformed_csv}

  defp parse_bytes(<<>>, _state, field, row, rows) do
    {:ok, Enum.reverse([finish_field(field) | row]) |> then(&Enum.reverse([&1 | rows]))}
  end

  defp parse_bytes(<<?", rest::binary>>, :field, [], row, rows),
    do: parse_bytes(rest, :quoted, [], row, rows)

  defp parse_bytes(<<?", ?", rest::binary>>, :quoted, field, row, rows),
    do: parse_bytes(rest, :quoted, [?" | field], row, rows)

  defp parse_bytes(<<?", rest::binary>>, :quoted, field, row, rows),
    do: parse_bytes(rest, :after_quote, field, row, rows)

  defp parse_bytes(<<?,, rest::binary>>, state, field, row, rows)
       when state in [:field, :after_quote],
       do: parse_bytes(rest, :field, [], [finish_field(field) | row], rows)

  defp parse_bytes(<<?\n, rest::binary>>, state, field, row, rows)
       when state in [:field, :after_quote] do
    finished = Enum.reverse([finish_field(field) | row])
    parse_bytes(rest, :field, [], [], [finished | rows])
  end

  defp parse_bytes(<<byte, rest::binary>>, :after_quote, field, row, rows)
       when byte in [32, 9],
       do: parse_bytes(rest, :after_quote, field, row, rows)

  defp parse_bytes(<<byte, rest::binary>>, state, field, row, rows),
    do: parse_bytes(rest, state, [byte | field], row, rows)

  defp finish_field(bytes), do: bytes |> Enum.reverse() |> :erlang.list_to_binary()
end
