defmodule SuperX.Workers.QueueDispatcher do
  @moduledoc """
  Runs every minute and enqueues a publish job for each post that has
  come due.

  It only *dispatches* — the actual publish happens in `PublishPost`, so
  one slow X call can't hold up the rest of the tick.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  require Logger

  alias SuperX.Accounts.User
  alias SuperX.{Content, Repo}
  alias SuperX.Workers.PublishPost

  @impl Oban.Worker
  def perform(_job) do
    posts = Content.list_due_posts()

    if posts != [] do
      Logger.info("Dispatching #{length(posts)} due post(s)")
    end

    jitter_by_user = jitter_by_user(posts)

    Enum.each(posts, fn post ->
      %{post_id: post.id}
      |> PublishPost.new(schedule_opts(jitter_by_user[post.user_id]))
      |> Oban.insert()
    end)

    :ok
  end

  # Jitter is a per-owner preference stored in user settings, not on the
  # post, so one lookup covers the whole tick however many posts are due.
  defp jitter_by_user([]), do: %{}

  defp jitter_by_user(posts) do
    user_ids = posts |> Enum.map(& &1.user_id) |> Enum.uniq()

    User
    |> where([user], user.id in ^user_ids)
    |> select([user], {user.id, user.settings})
    |> Repo.all()
    |> Map.new(fn {id, settings} -> {id, jitter_minutes(settings)} end)
  end

  # Anything unreadable means "no jitter" — a botched settings write must
  # never hold a post back from going out on time.
  defp jitter_minutes(settings) when is_map(settings) do
    case Integer.parse(to_string(settings["queue_jitter_minutes"])) do
      {minutes, ""} when minutes in 1..5 -> minutes
      _ -> 0
    end
  end

  defp jitter_minutes(_settings), do: 0

  # The post's own scheduled_at must stay slot-exact (Slot matches
  # occurrences by timestamp, and scheduling claims a time by equality), so
  # the jitter lives only on the job: it delays, never publishes early.
  defp schedule_opts(0), do: []
  defp schedule_opts(minutes), do: [schedule_in: :rand.uniform(minutes * 60)]
end
