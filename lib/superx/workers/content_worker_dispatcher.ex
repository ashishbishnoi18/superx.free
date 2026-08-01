defmodule SuperX.Workers.ContentWorkerDispatcher do
  @moduledoc """
  Turns due local-time worker schedules into isolated generation jobs.

  Dispatch stays separate from generation so a slow model call cannot
  hold up schedule checks for the other accounts on the node.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 50]

  require Logger

  alias SuperX.Workers

  @impl Oban.Worker
  def perform(_job) do
    if SuperX.AI.configured?() do
      dispatch_due()
    else
      Logger.debug("Skipping content workers: no LLM configured")
    end

    :ok
  end

  defp dispatch_due do
    workers = Workers.list_due_content_workers()

    if workers != [] do
      Logger.info("Dispatching #{length(workers)} due content worker(s)")
    end

    Enum.each(workers, &Workers.enqueue/1)
  end
end
