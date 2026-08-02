defmodule SuperX.Accounts.Connect do
  @moduledoc """
  Turns a completed X OAuth handshake into a usable account.

  Handles both entry points:

    * signing in — the X account either belongs to an existing user or
      provisions a new one;
    * connecting an extra account to a session that already exists.

  Provisioning a fresh user also creates their plan, quota windows,
  default publishing slots, and an empty voice profile, so every part of
  the app has something to read immediately after first login.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SuperX.Accounts
  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Content.{ScheduleSlot, VoiceProfile}
  alias SuperX.Repo

  @type profile :: %{
          required(:x_user_id) => String.t(),
          required(:handle) => String.t(),
          optional(:display_name) => String.t() | nil,
          optional(:avatar_url) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:followers_count) => integer(),
          optional(:following_count) => integer(),
          optional(:posts_count) => integer()
        }

  @doc """
  Signs a user in from an X profile and token set.

  Reconnecting an account that is already linked updates it in place and
  returns the owning user, so re-running the flow is safe.
  """
  @spec sign_in(profile(), map()) :: {:ok, User.t(), XAccount.t()} | {:error, term()}
  def sign_in(profile, tokens) do
    case Accounts.get_x_account_by_x_user_id(profile.x_user_id) do
      %XAccount{} = existing ->
        with {:ok, account} <- refresh_existing(existing, profile, tokens) do
          {:ok, Accounts.get_user_with_context!(account.user_id), account}
        end

      nil ->
        provision_new_user(profile, tokens)
    end
  end

  @doc """
  Attaches an additional X account to an existing user.

  Refuses if the account is already linked elsewhere — silently moving it
  would let someone hijack another user's connected account by
  re-authorising it.
  """
  @spec attach(User.t(), profile(), map()) ::
          {:ok, XAccount.t()} | {:error, :already_linked | :account_limit_reached | term()}
  def attach(%User{} = user, profile, tokens) do
    existing = Accounts.get_x_account_by_x_user_id(profile.x_user_id)
    user_id = user.id

    cond do
      match?(%XAccount{user_id: ^user_id}, existing) ->
        refresh_existing(existing, profile, tokens)

      not is_nil(existing) ->
        {:error, :already_linked}

      not SuperX.Billing.can_connect_account?(user, count_accounts(user)) ->
        {:error, :account_limit_reached}

      true ->
        insert_account(user, profile, tokens)
    end
  end

  # --- Internals -----------------------------------------------------------

  defp provision_new_user(profile, tokens) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.insert(:user, fn _ ->
      User.changeset(%User{}, %{
        name: profile[:display_name] || profile.handle,
        avatar_url: profile[:avatar_url],
        settings: User.default_settings()
      })
    end)
    |> Multi.insert(:x_account, fn %{user: user} ->
      account_changeset(user, profile, tokens, now)
    end)
    # Act as the account they just signed in with.
    |> Multi.update(:set_default, fn %{user: user, x_account: account} ->
      User.changeset(user, %{default_x_account_id: account.id})
    end)
    |> Multi.insert(:voice_profile, fn %{x_account: account} ->
      VoiceProfile.changeset(%VoiceProfile{}, %{x_account_id: account.id})
    end)
    |> Multi.insert_all(:slots, ScheduleSlot, fn %{x_account: account} ->
      Enum.map(ScheduleSlot.defaults(), fn slot ->
        %{
          id: Ecto.UUID.generate(),
          x_account_id: account.id,
          day_of_week: slot.day_of_week,
          time: slot.time,
          enabled: true,
          inserted_at: now,
          updated_at: now
        }
      end)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{set_default: user, x_account: account}} ->
        # Plan and quota rows are written outside the transaction so a
        # billing hiccup can't block someone from signing up.
        {:ok, _} = SuperX.Billing.provision(user)
        {:ok, Accounts.get_user_with_context!(user.id), account}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp insert_account(%User{} = user, profile, tokens) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.insert(:x_account, account_changeset(user, profile, tokens, now))
    |> Multi.insert(:voice_profile, fn %{x_account: account} ->
      VoiceProfile.changeset(%VoiceProfile{}, %{x_account_id: account.id})
    end)
    |> Multi.insert_all(:slots, ScheduleSlot, fn %{x_account: account} ->
      Enum.map(ScheduleSlot.defaults(), fn slot ->
        %{
          id: Ecto.UUID.generate(),
          x_account_id: account.id,
          day_of_week: slot.day_of_week,
          time: slot.time,
          enabled: true,
          inserted_at: now,
          updated_at: now
        }
      end)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{x_account: account}} -> {:ok, account}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp account_changeset(%User{} = user, profile, tokens, now) do
    %XAccount{user_id: user.id}
    |> XAccount.profile_changeset(Map.put(profile, :last_synced_at, now))
    |> XAccount.token_changeset(tokens)
  end

  defp refresh_existing(%XAccount{} = account, profile, tokens) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    account
    |> XAccount.profile_changeset(Map.put(profile, :last_synced_at, now))
    |> XAccount.token_changeset(tokens)
    |> Repo.update()
  end

  defp count_accounts(%User{} = user) do
    XAccount
    |> where([a], a.user_id == ^user.id and is_nil(a.disconnected_at))
    |> select(count())
    |> Repo.one()
  end
end
