defmodule SuperX.Workers.SignalSweep do
  @moduledoc """
  Runs the watch agents that are due.

  Each agent's leads count against the owner's `leads_day` quota. Exhausted
  quotas are checked before a billable read and shown on the agent; the agent
  remains enabled so it resumes automatically after the rolling window resets.
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

  @doc "Runs one agent with the same quota and bookkeeping used by scheduled sweeps."
  def run_agent(agent) do
    user = Repo.get!(User, agent.x_account.user_id)
    quota = Billing.get_quota(user, "leads_day")

    if quota.used >= quota.limit do
      details = %{
        key: quota.key,
        used: quota.used,
        limit: quota.limit,
        resets_at: quota.window_end
      }

      Signals.record_run(agent, 0, quota_message(details))
      {:error, :quota_exceeded, details}
    else
      run_agent(agent, user, quota.limit - quota.used)
    end
  end

  defp run_agent(agent, user, remaining) do
    case Scout.run(agent, max_new_leads: remaining) do
      {:ok, 0} ->
        Signals.record_run(agent, 0)
        {:ok, 0}

      {:ok, count} ->
        # Charged after the fact: the watch returns what it returns, and
        # refusing to record leads we already paid the API for would be
        # the worst of both.
        case Billing.claim(user, "leads_day", count) do
          {:ok, quota} ->
            error =
              if quota.used >= quota.limit, do: quota_message(%{resets_at: quota.window_end})

            Signals.record_run(agent, count, error)
            Logger.info("Agent #{agent.name} found #{count} lead(s)")
            {:ok, count}

          {:error, :quota_exceeded, details} ->
            Logger.info(
              "@#{agent.x_account.handle} reached its daily lead quota while running #{agent.name}"
            )

            Signals.record_run(agent, count, quota_message(details))
            {:error, :quota_exceeded, details}
        end

      {:error, :out_of_credits} ->
        Signals.record_run(agent, 0, "twitterapi.io is out of credits")
        {:error, :out_of_credits}

      {:error, reason} ->
        Logger.warning("Agent #{agent.name} failed: #{inspect(reason)}")
        Signals.record_run(agent, 0, describe(reason))
        {:error, reason}
    end
  end

  defp quota_message(%{resets_at: resets_at}) do
    "Daily lead quota reached; resets #{DateTime.to_iso8601(resets_at)}"
  end

  defp describe({:http_error, status, _}), do: "X data provider returned #{status}"
  defp describe(:rate_limited), do: "Rate limited; will retry"
  defp describe(other), do: other |> inspect() |> String.slice(0, 200)
end
