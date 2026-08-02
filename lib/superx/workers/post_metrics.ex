defmodule SuperX.Workers.PostMetrics do
  @moduledoc """
  Refreshes like and view counts on recently published posts.

  The numbers feed the performance-gated automations — auto-plug fires at
  a like threshold, auto-delete below a view floor — so they must be
  fresher than the six-hour cache a voice profile tolerates. Every fetch
  still bills per tweet returned, so the run makes one call per account
  and matches it locally against everything that account published in the
  last month.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 2

  import Ecto.Query

  require Logger

  alias SuperX.Accounts.XAccount
  alias SuperX.Content.Post
  alias SuperX.{Content, Repo, TwitterAPI}

  # Metrics older than a month tell an automation nothing it can act on.
  @lookback_days 30
  # Half an hour: a like threshold crossed just after a run still gets
  # plugged while the post is moving.
  @metrics_ttl 1800

  @impl Oban.Worker
  def perform(_job) do
    if TwitterAPI.configured?() do
      XAccount
      |> where([a], not a.reauth_needed)
      |> Repo.all()
      |> Enum.each(&sync_account/1)
    end

    :ok
  end

  # One fetch per account; a failure skips that account, not the run.
  defp sync_account(%XAccount{} = account) do
    case TwitterAPI.user_tweets(account.handle, max: 100, ttl: @metrics_ttl) do
      {:ok, tweets} ->
        account
        |> recent_posts()
        |> metrics_updates(tweets)
        |> Enum.each(fn {post, metrics} ->
          {:ok, _} = Content.update_metrics(post, metrics)
        end)

      {:error, reason} ->
        Logger.warning("Post metrics failed for @#{account.handle}: #{inspect(reason)}")
    end

    :ok
  end

  defp recent_posts(%XAccount{} = account) do
    cutoff = DateTime.add(DateTime.utc_now(), -@lookback_days * 24 * 3600, :second)

    Post
    |> where([p], p.x_account_id == ^account.id)
    |> where([p], p.status == "posted" and p.published_at >= ^cutoff)
    |> where([p], fragment("cardinality(?)", p.x_post_ids) > 0)
    |> Repo.all()
  end

  @doc false
  # Only the first X id is matched: it heads the thread, so it carries the
  # numbers the automations gate on.
  def metrics_updates(posts, tweets) do
    by_id = Map.new(tweets, &{&1["id"], &1})

    Enum.flat_map(posts, fn post ->
      with [first_id | _] <- post.x_post_ids,
           %{} = tweet <- Map.get(by_id, first_id),
           {:ok, metrics} <- tweet_metrics(tweet) do
        [{post, metrics}]
      else
        _ -> []
      end
    end)
  end

  defp tweet_metrics(tweet) do
    with likes when is_integer(likes) and likes >= 0 <- tweet["likeCount"],
         views when is_integer(views) and views >= 0 <- tweet["viewCount"] do
      metrics =
        %{"likes" => likes, "views" => views}
        |> put_metric("reposts", tweet["retweetCount"])
        |> put_metric("replies", tweet["replyCount"])

      {:ok, metrics}
    else
      _invalid -> {:error, :invalid_metrics}
    end
  end

  defp put_metric(metrics, key, value) when is_integer(value) and value >= 0,
    do: Map.put(metrics, key, value)

  defp put_metric(metrics, _key, _value), do: metrics
end
