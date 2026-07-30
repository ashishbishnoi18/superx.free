defmodule SuperX.Workers.QueueDispatcher do
  @moduledoc """
  Runs every minute and enqueues a publish job for each post that has
  come due.

  It only *dispatches* — the actual publish happens in `PublishPost`, so
  one slow X call can't hold up the rest of the tick.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias SuperX.Content
  alias SuperX.Workers.PublishPost

  @impl Oban.Worker
  def perform(_job) do
    posts = Content.list_due_posts()

    if posts != [] do
      Logger.info("Dispatching #{length(posts)} due post(s)")
    end

    Enum.each(posts, fn post ->
      %{post_id: post.id}
      |> PublishPost.new()
      |> Oban.insert()
    end)

    :ok
  end
end
