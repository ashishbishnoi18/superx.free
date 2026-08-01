defmodule SuperX.Workers.SignalSweep do
  @moduledoc """
  Runs the watch agents that are due.

  Each agent's leads count against the owner's `leads_day` quota, claimed
  after the fact because the API tells us how many we found, not how many
  we will. An agent that blows through the quota is paused for the day
  rather than silently continuing to spend.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 2, unique: [period: 600]

  require Logger

  alias SuperX.Accounts.User
  alias SuperX.{Billing, Repo, Signals, TwitterAPI}
  alias SuperX.Signals.Scout

  @impl Oban.Worker
  def perform(_job) do
    if TwitterAPI.configured?() do
      Signals.agents_due() |> Enum.each(&run_agent/1)
    else
      Logger.debug("Skipping signal sweep: twitterapi.io not configured")
    end

    :ok
  end

  defp run_agent(agent) do
    user = Repo.get!(User, agent.x_account.user_id)

    case Scout.run(agent) do
      {:ok, 0} ->
        Signals.record_run(agent, 0)

      {:ok, count} ->
        # Charged after the fact: the watch returns what it returns, and
        # refusing to record leads we already paid the API for would be
        # the worst of both.
        case Billing.claim(user, "leads_day", count) do
          {:ok, _} ->
            :ok

          {:error, :quota_exceeded, _details} ->
            Logger.info(
              "@#{agent.x_account.handle} is over its daily lead quota; pausing #{agent.name}"
            )

            Signals.update_agent(agent, %{enabled: false, last_error: "Daily lead quota reached"})
        end

        Signals.record_run(agent, count)
        Logger.info("Agent #{agent.name} found #{count} lead(s)")

      {:error, :out_of_credits} ->
        Signals.record_run(agent, 0, "twitterapi.io is out of credits")

      {:error, reason} ->
        Logger.warning("Agent #{agent.name} failed: #{inspect(reason)}")
        Signals.record_run(agent, 0, describe(reason))
    end
  end

  defp describe({:http_error, status, _}), do: "X data provider returned #{status}"
  defp describe(:rate_limited), do: "Rate limited; will retry"
  defp describe(other), do: other |> inspect() |> String.slice(0, 200)
end
