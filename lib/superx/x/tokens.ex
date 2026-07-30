defmodule SuperX.X.Tokens do
  @moduledoc """
  Keeps X access tokens alive.

  X issues short-lived access tokens (two hours) alongside a rotating
  refresh token: each refresh returns a *new* refresh token and
  invalidates the old one. That makes concurrent refreshes actively
  harmful — two in-flight refreshes for the same account will race, and
  the loser persists a refresh token that X has already revoked.

  Refreshes are therefore serialised per account through a lock on the
  account row.
  """

  require Logger

  alias SuperX.Accounts
  alias SuperX.Accounts.XAccount
  alias SuperX.Repo

  @doc """
  Returns a usable access token for the account, refreshing first if it
  is missing or close to expiry.
  """
  @spec fresh_token(XAccount.t()) ::
          {:ok, String.t(), XAccount.t()} | {:error, :reauth_required | term()}
  def fresh_token(%XAccount{} = account) do
    cond do
      account.reauth_needed ->
        {:error, :reauth_required}

      not XAccount.token_stale?(account) ->
        {:ok, account.access_token, account}

      is_nil(account.refresh_token) ->
        Accounts.flag_reauth(account, "No refresh token stored")
        {:error, :reauth_required}

      true ->
        refresh(account)
    end
  end

  @doc """
  Refreshes an account's tokens, serialised against concurrent callers.

  If another process refreshed while we waited for the lock, the reloaded
  row already has a live token and we return it without calling X.
  """
  @spec refresh(XAccount.t()) ::
          {:ok, String.t(), XAccount.t()} | {:error, :reauth_required | term()}
  def refresh(%XAccount{} = account) do
    Repo.transaction(fn ->
      locked = Repo.get!(XAccount, account.id, lock: "FOR UPDATE")

      cond do
        locked.reauth_needed ->
          {:error, :reauth_required}

        # Someone else already did the work while we blocked on the lock.
        not XAccount.token_stale?(locked) ->
          {:ok, locked.access_token, locked}

        is_nil(locked.refresh_token) ->
          Accounts.flag_reauth(locked, "No refresh token stored")
          {:error, :reauth_required}

        true ->
          do_refresh(locked)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_refresh(%XAccount{} = account) do
    case SuperX.X.refresh_token(account.refresh_token) do
      {:ok, tokens} ->
        case Accounts.update_x_account_tokens(account, tokens) do
          {:ok, updated} ->
            {:ok, updated.access_token, updated}

          {:error, changeset} ->
            {:error, changeset}
        end

      # X rejected the refresh token: it was rotated out, revoked, or the
      # user removed the app. Only the user can fix this.
      {:error, {:unauthorized, _body}} ->
        Logger.info("X refresh rejected for @#{account.handle}; flagging for reauth")
        Accounts.flag_reauth(account, "X rejected the stored credentials")
        {:error, :reauth_required}

      {:error, {:http_error, 400, _body}} ->
        Accounts.flag_reauth(account, "X rejected the stored credentials")
        {:error, :reauth_required}

      # Network blips and 5xx are transient — leave the account alone so
      # the next attempt can succeed.
      {:error, reason} ->
        Logger.warning("X refresh failed for @#{account.handle}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
