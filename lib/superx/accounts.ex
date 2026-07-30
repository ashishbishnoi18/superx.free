defmodule SuperX.Accounts do
  @moduledoc """
  Users, their connected X accounts, and browser sessions.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SuperX.Accounts.{OAuthRequest, Session, User, XAccount}
  alias SuperX.Repo

  # --- Users ---------------------------------------------------------------

  def get_user(id), do: Repo.get(User, id)
  def get_user!(id), do: Repo.get!(User, id)

  @doc "Loads a user with everything the app shell needs on each page."
  def get_user_with_context!(id) do
    User
    |> where(id: ^id)
    |> preload([:x_accounts, :subscription])
    |> Repo.one!()
  end

  def update_user(%User{} = user, attrs) do
    user |> User.changeset(attrs) |> Repo.update()
  end

  @doc "Merges a partial settings map into the user's stored settings."
  def update_settings(%User{} = user, partial) when is_map(partial) do
    settings = Map.merge(user.settings || %{}, stringify_keys(partial))
    update_user(user, %{settings: settings})
  end

  @doc "Reads a setting, falling back to the shipped defaults."
  def setting(%User{settings: settings}, key) do
    Map.get(settings || %{}, key, Map.get(User.default_settings(), key))
  end

  def touch_last_seen(%User{} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, _} =
      User |> where(id: ^user.id) |> Repo.update_all(set: [last_seen_at: now, updated_at: now])

    :ok
  end

  # --- X accounts ----------------------------------------------------------

  def get_x_account(id), do: Repo.get(XAccount, id)

  def get_x_account_by_x_user_id(x_user_id) do
    Repo.get_by(XAccount, x_user_id: x_user_id)
  end

  @doc "All accounts a user can act as, oldest first."
  def list_x_accounts(%User{} = user) do
    XAccount |> where(user_id: ^user.id) |> order_by(asc: :inserted_at) |> Repo.all()
  end

  @doc """
  Resolves the account the user is currently acting as: their explicit
  default, or the first connected account.
  """
  def current_x_account(%User{} = user) do
    cond do
      user.default_x_account_id ->
        Repo.get_by(XAccount, id: user.default_x_account_id, user_id: user.id) ||
          first_x_account(user)

      true ->
        first_x_account(user)
    end
  end

  defp first_x_account(%User{} = user) do
    XAccount |> where(user_id: ^user.id) |> order_by(asc: :inserted_at) |> limit(1) |> Repo.one()
  end

  @doc "Switches the account the user acts as. Refuses accounts they don't own."
  def set_default_x_account(%User{} = user, x_account_id) do
    case Repo.get_by(XAccount, id: x_account_id, user_id: user.id) do
      nil -> {:error, :not_found}
      account -> update_user(user, %{default_x_account_id: account.id})
    end
  end

  def update_x_account_profile(%XAccount{} = account, attrs) do
    account |> XAccount.profile_changeset(attrs) |> Repo.update()
  end

  def update_x_account_tokens(%XAccount{} = account, attrs) do
    account |> XAccount.token_changeset(attrs) |> Repo.update()
  end

  @doc "Flags an account as needing reconnection and clears its dead tokens."
  def flag_reauth(%XAccount{} = account, reason) do
    account
    |> XAccount.reauth_changeset(reason)
    |> Ecto.Changeset.put_change(:access_token, nil)
    |> Ecto.Changeset.put_change(:refresh_token, nil)
    |> Repo.update()
  end

  @doc "Accounts whose tokens expire soon, for the refresh worker."
  def list_x_accounts_needing_refresh(within_seconds \\ 900) do
    cutoff = DateTime.utc_now() |> DateTime.add(within_seconds, :second)

    XAccount
    |> where([a], not a.reauth_needed)
    |> where([a], not is_nil(a.refresh_token))
    |> where([a], a.token_expires_at <= ^cutoff)
    |> Repo.all()
  end

  @doc """
  Disconnects an account. Scheduled posts for it are cancelled rather
  than deleted, so the user can see what didn't go out.
  """
  def disconnect_x_account(%User{} = user, x_account_id) do
    case Repo.get_by(XAccount, id: x_account_id, user_id: user.id) do
      nil ->
        {:error, :not_found}

      account ->
        Multi.new()
        |> Multi.update_all(
          :cancel_scheduled,
          from(p in SuperX.Content.Post,
            where: p.x_account_id == ^account.id and p.status == "scheduled"
          ),
          set: [status: "cancelled"]
        )
        |> Multi.delete(:account, account)
        |> Repo.transaction()
    end
  end

  # --- OAuth handshakes ----------------------------------------------------

  def create_oauth_request(attrs \\ %{}) do
    attrs |> OAuthRequest.build() |> Repo.insert()
  end

  @doc """
  Consumes a handshake by state. Single-use: the row is deleted as it is
  read, so a replayed callback cannot mint a second session.
  """
  def consume_oauth_request(state) when is_binary(state) do
    now = DateTime.utc_now()

    query =
      from(r in OAuthRequest, where: r.state == ^state and r.expires_at > ^now, select: r)

    case Repo.delete_all(query) do
      {1, [request]} -> {:ok, request}
      _ -> {:error, :invalid_state}
    end
  end

  def prune_oauth_requests do
    now = DateTime.utc_now()
    {count, _} = OAuthRequest |> where([r], r.expires_at <= ^now) |> Repo.delete_all()
    count
  end

  # --- Sessions ------------------------------------------------------------

  @doc "Creates a session and returns the token to store in the cookie."
  def create_session(%User{} = user, attrs \\ %{}) do
    {token, session} = Session.build(user, attrs)

    case Repo.insert(session) do
      {:ok, _session} -> {:ok, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Resolves a cookie token to its user, or nil."
  def get_user_by_session_token(nil), do: nil

  def get_user_by_session_token(token) when is_binary(token) do
    with {:ok, raw} <- Session.decode(token) do
      hash = Session.hash(raw)
      now = DateTime.utc_now()

      User
      |> join(:inner, [u], s in Session, on: s.user_id == u.id)
      |> where([_u, s], s.token_hash == ^hash and s.expires_at > ^now)
      |> preload([:x_accounts, :subscription])
      |> Repo.one()
    else
      _ -> nil
    end
  end

  @doc "Revokes a single session."
  def delete_session_token(token) when is_binary(token) do
    with {:ok, raw} <- Session.decode(token) do
      hash = Session.hash(raw)
      Session |> where(token_hash: ^hash) |> Repo.delete_all()
      :ok
    else
      _ -> :ok
    end
  end

  def delete_session_token(_), do: :ok

  @doc "Revokes every session for a user."
  def delete_all_sessions(%User{} = user) do
    Session |> where(user_id: ^user.id) |> Repo.delete_all()
    :ok
  end

  def prune_sessions do
    now = DateTime.utc_now()
    {count, _} = Session |> where([s], s.expires_at <= ^now) |> Repo.delete_all()
    count
  end

  # --- Helpers -------------------------------------------------------------

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
