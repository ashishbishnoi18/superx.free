defmodule SuperX.Workers.AutomationMonitor do
  @moduledoc """
  Fires the automations attached to published posts: reposting your own
  winner, undoing the repost later, plugging a link once the post proves
  itself, deleting a flop.

  These actions publish or destroy content under the user's name, so the
  module is split in two: `pending_actions/2` decides what is provisionally
  due without touching the network — pure, and testable — and the executor
  verifies destructive thresholds against X itself. Every action taken is recorded in the post's
  `automation_state`, so a re-run never acts twice.
  """

  use Oban.Worker, queue: :publishing, max_attempts: 3

  import Ecto.Query

  require Logger

  alias SuperX.Content.Post
  alias SuperX.{Content, Repo, X}

  @lookback_days 30
  @metrics_max_age_seconds 3600

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    now
    |> candidates()
    |> Enum.group_by(& &1.x_account)
    |> Enum.each(fn {account, posts} -> run_account(account, posts, now) end)

    :ok
  end

  defp candidates(now) do
    cutoff = DateTime.add(now, -@lookback_days * 24 * 3600, :second)

    Post
    |> where([p], p.status == "posted" and p.published_at >= ^cutoff)
    |> where(
      [p],
      not is_nil(p.auto_retweet_hours) or not is_nil(p.auto_retweet_undo_hours) or
        not is_nil(p.auto_plug_likes) or not is_nil(p.auto_delete_min_views)
    )
    |> where([p], fragment("cardinality(?)", p.x_post_ids) > 0)
    |> preload(:x_account)
    |> Repo.all()
  end

  # A dead token or a rate limit stops the whole account for this run:
  # the next post would hit the same wall, and pushing on risks the
  # account's standing with X.
  defp run_account(account, posts, now) do
    case X.Tokens.fresh_token(account) do
      {:ok, token, account} ->
        Enum.reduce_while(posts, :ok, fn post, :ok ->
          case run_post(account, post, token, now) do
            :ok -> {:cont, :ok}
            :rate_limited -> {:halt, :rate_limited}
          end
        end)

      {:error, :reauth_required} ->
        Logger.debug("Skipping automations for @#{account.handle}: needs reconnect")

      {:error, reason} ->
        Logger.warning("Automations skipped for @#{account.handle}: #{inspect(reason)}")
    end

    :ok
  end

  # The post struct is threaded through the actions so two markers written
  # in one run merge forward instead of the second erasing the first.
  defp run_post(account, post, token, now) do
    post
    |> pending_actions(now)
    |> Enum.reduce_while({:ok, post}, fn action, {:ok, post} ->
      case act(action, account, post, token, now) do
        {:ok, post} ->
          {:cont, {:ok, post}}

        {:error, {:rate_limited, retry_after}} ->
          Logger.warning(
            "Automation #{action} rate-limited on post #{post.id}; " <>
              "pausing @#{account.handle} for #{retry_after}s"
          )

          {:halt, :rate_limited}

        {:error, reason} ->
          Logger.warning("Automation #{action} failed on post #{post.id}: #{inspect(reason)}")
          {:cont, {:ok, post}}
      end
    end)
    |> case do
      {:ok, _post} -> :ok
      :rate_limited -> :rate_limited
    end
  end

  defp act(action, account, post, token, now) do
    action_name = Atom.to_string(action)

    case Content.claim_automation_action(post, action_name, now) do
      {:ok, claimed} ->
        execute_claimed(action, account, claimed, token, now)

      {:error, :already_claimed} ->
        # Another worker owns this post, or a prior provider call completed
        # without a safely persisted response. Both cases fail closed.
        {:ok, Repo.get!(Post, post.id)}
    end
  end

  defp execute_claimed(action, account, post, token, now) do
    first_id = hd(post.x_post_ids)

    result =
      case action do
        :retweet -> X.retweet(account.x_user_id, first_id, token)
        :unretweet -> X.unretweet(account.x_user_id, first_id, token)
        :plug -> X.create_post(token, post.auto_plug_text, reply_to: first_id)
        :delete -> delete_if_still_below_threshold(post, first_id, token)
      end

    case result do
      {:ok, _response} ->
        case Content.complete_automation_action(post, Atom.to_string(action), now) do
          {:ok, completed} ->
            Logger.info("Automation #{action} fired on post #{post.id}")
            {:ok, completed}

          {:error, reason} ->
            # The durable claim remains. Retrying the provider request would
            # risk duplicating an action that already succeeded.
            {:error, {:state_persist_failed, reason}}
        end

      {:error, reason} ->
        handle_action_error(action, post, reason)
    end
  end

  defp handle_action_error(action, post, reason) do
    action_name = Atom.to_string(action)

    if permanent?(reason) do
      case Content.fail_automation_action(post, action_name, describe(reason)) do
        {:ok, failed} -> {:ok, failed}
        {:error, persist_reason} -> {:error, {:state_persist_failed, persist_reason}}
      end
    else
      case Content.release_automation_action(post, action_name) do
        {:ok, _released} -> {:error, reason}
        {:error, persist_reason} -> {:error, {:claim_release_failed, persist_reason}}
      end
    end
  end

  defp delete_if_still_below_threshold(post, first_id, token) do
    case X.post_metrics(first_id, token) do
      {:ok, %{views: views}} when views < post.auto_delete_min_views ->
        X.delete_post(first_id, token)

      {:ok, %{views: views}} ->
        {:error, {:delete_threshold_met, views}}

      {:error, _reason} = error ->
        error
    end
  end

  # X documents 4xx as request/auth problems; 429 never reaches here
  # because the client reports it as :rate_limited.
  defp permanent?({:http_error, status, _body}) when status in 400..499, do: true
  defp permanent?({:unauthorized, _body}), do: true
  defp permanent?({:delete_threshold_met, _views}), do: true
  defp permanent?(_reason), do: false

  defp describe({:http_error, status, _body}), do: "X returned #{status}"
  defp describe({:unauthorized, _body}), do: "X rejected the request"
  defp describe({:delete_threshold_met, views}), do: "X reported #{views} views; delete cancelled"
  defp describe(other), do: other |> inspect() |> String.slice(0, 200)

  @doc """
  Which automations are due for `post` at `now`, in firing order.

  An action is due when its trigger is configured, its condition holds,
  and neither its done marker nor a terminal failure is recorded.
  """
  @spec pending_actions(Post.t(), DateTime.t()) :: [
          :retweet | :unretweet | :plug | :delete
        ]
  def pending_actions(%Post{} = post, %DateTime{} = now) do
    state = post.automation_state || %{}

    if claim_in_progress?(state) do
      []
    else
      [
        {:retweet, retweet_due?(post, state, now)},
        {:unretweet, unretweet_due?(post, state, now)},
        {:plug, plug_due?(post, state, now)},
        {:delete, delete_due?(post, state, now)}
      ]
      |> Enum.filter(fn {_action, due?} -> due? end)
      |> Enum.map(fn {action, _due?} -> action end)
    end
  end

  defp retweet_due?(post, state, now) do
    not is_nil(post.auto_retweet_hours) and
      elapsed?(post.published_at, post.auto_retweet_hours, now) and
      is_nil(state["retweeted_at"]) and
      is_nil(state["failed_retweet"])
  end

  # Undo only makes sense once the repost exists, which the marker proves.
  defp unretweet_due?(post, state, now) do
    with hours when is_integer(hours) <- post.auto_retweet_undo_hours,
         %DateTime{} = retweeted_at <- state_time(state["retweeted_at"]) do
      elapsed?(retweeted_at, hours, now) and
        is_nil(state["unretweeted_at"]) and
        is_nil(state["failed_unretweet"])
    else
      _ -> false
    end
  end

  # Without fresh metrics there is nothing to weigh the threshold against,
  # so the plug simply waits for the next metrics run.
  defp plug_due?(post, state, now) do
    likes = metric(post, "likes")

    not is_nil(post.auto_plug_likes) and
      not is_nil(post.auto_plug_text) and
      is_nil(state["plugged_at"]) and
      is_nil(state["failed_plug"]) and
      fresh_metrics?(post.metrics_updated_at, now) and
      not is_nil(likes) and
      likes >= post.auto_plug_likes
  end

  # Deleting on unknown numbers would punish a post for our failure to
  # measure it, so absent or stale metrics freeze this automation rather
  # than fire it.
  defp delete_due?(post, state, now) do
    views = metric(post, "views")

    not is_nil(post.auto_delete_min_views) and
      not is_nil(post.auto_delete_hours) and
      elapsed?(post.published_at, post.auto_delete_hours, now) and
      is_nil(state["deleted_at"]) and
      is_nil(state["failed_delete"]) and
      fresh_metrics?(post.metrics_updated_at, now) and
      not is_nil(views) and
      views < post.auto_delete_min_views
  end

  defp elapsed?(nil, _hours, _now), do: false

  defp elapsed?(%DateTime{} = since, hours, %DateTime{} = now) do
    DateTime.compare(DateTime.add(since, hours * 3600, :second), now) != :gt
  end

  defp state_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp state_time(_value), do: nil

  defp fresh_metrics?(%DateTime{} = updated_at, %DateTime{} = now) do
    DateTime.diff(now, updated_at, :second) in 0..@metrics_max_age_seconds
  end

  defp fresh_metrics?(_updated_at, _now), do: false

  defp claim_in_progress?(state) do
    Enum.any?(state, fn {key, _value} -> String.starts_with?(key, "claimed_") end)
  end

  defp metric(%Post{metrics: metrics}, key) when is_map(metrics) do
    case metrics[key] do
      value when is_integer(value) and value >= 0 -> value
      _other -> nil
    end
  end

  defp metric(_post, _key), do: nil
end
