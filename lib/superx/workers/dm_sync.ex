defmodule SuperX.Workers.DMSync do
  @moduledoc """
  Keeps enabled accounts' private inboxes current through user-authenticated
  X API reads.

  The feature flag is checked before loading accounts so an installation that
  has not enabled the X app's DM permission tier makes no read calls at all.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 240]

  import Ecto.Query

  require Logger

  alias SuperX.Accounts.XAccount
  alias SuperX.{DMs, Repo, X}

  @impl Oban.Worker
  def perform(_job) do
    if X.dms_enabled?(), do: sync_accounts(), else: :ok
  end

  defp sync_accounts do
    XAccount
    |> where([account], not account.reauth_needed)
    |> Repo.all()
    |> Enum.reduce_while(:ok, &sync_account/2)
  end

  defp sync_account(account, _result) do
    case DMs.sync(account) do
      {:ok, _result} ->
        {:cont, :ok}

      {:error, :reauth_required} ->
        Logger.info("Skipping DM sync for @#{account.handle}: needs reconnect")
        {:cont, :ok}

      {:error, {:dm_permission_tier_required, _body}} ->
        Logger.error(
          "DM sync stopped: the X app has not been granted the Direct Message permission tier"
        )

        {:halt, :ok}

      {:error, {:rate_limited, retry_after}} ->
        {:halt, {:snooze, retry_after}}

      {:error, :disabled} ->
        {:halt, :ok}

      {:error, reason} ->
        Logger.warning("DM sync failed for @#{account.handle}: #{inspect(reason)}")
        {:halt, {:error, reason}}
    end
  end
end
