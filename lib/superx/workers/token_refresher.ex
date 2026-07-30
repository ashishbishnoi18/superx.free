defmodule SuperX.Workers.TokenRefresher do
  @moduledoc """
  Refreshes X access tokens ahead of expiry.

  Running this on a schedule rather than only on demand means a user's
  first publish of the day doesn't pay the refresh latency, and an
  account whose refresh token has been revoked gets flagged for reconnect
  before a post silently fails.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias SuperX.Accounts

  @impl Oban.Worker
  def perform(_job) do
    accounts = Accounts.list_x_accounts_needing_refresh()

    Enum.each(accounts, fn account ->
      case SuperX.X.Tokens.refresh(account) do
        {:ok, _token, _account} ->
          :ok

        {:error, :reauth_required} ->
          Logger.info("@#{account.handle} needs to reconnect")

        {:error, reason} ->
          Logger.warning("Token refresh failed for @#{account.handle}: #{inspect(reason)}")
      end
    end)

    # Opportunistic housekeeping on a job that already runs regularly.
    Accounts.prune_oauth_requests()
    Accounts.prune_sessions()

    :ok
  end
end
