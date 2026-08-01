defmodule SuperX.Teams do
  @moduledoc """
  Seats whose data stays separate while billing entitlement comes from an owner.

  Membership changes lock both users before inspecting either side. That keeps
  the one-level model true when two invitations are accepted concurrently,
  without introducing an organisation scope into any product data.
  """

  import Ecto.Query

  require Logger

  alias SuperX.Accounts.User
  alias SuperX.Mailer
  alias SuperX.Repo
  alias SuperX.Teams.{Invitation, InvitationEmail}

  @doc "Creates an invitation and returns the link whether or not email can be sent."
  def invite(%User{} = owner, attrs) do
    Repo.transaction(fn ->
      with {:ok, owner} <- lock_owner(owner),
           {:ok, invitation} <- owner |> Invitation.build(attrs) |> Repo.insert() do
        {:ok, owner, invitation}
      end
    end)
    |> unwrap_transaction()
    |> case do
      {:ok, owner, invitation} ->
        url = invitation_url(invitation)
        maybe_deliver(owner, invitation, url)
        {:ok, invitation, url}

      error ->
        error
    end
  end

  @doc "Returns the invitation form used before any token is persisted."
  def change_invitation(%User{} = owner, attrs \\ %{}) do
    Invitation.build(owner, attrs)
  end

  @doc "Lists invitations which can still be managed, newest first."
  def list_invitations(%User{} = owner) do
    Invitation
    |> where(owner_id: ^owner.id)
    |> where([invitation], invitation.status in ["pending", "expired"])
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> Enum.map(&expire_if_needed/1)
  end

  @doc "Returns team members without preloading any of their private account data."
  def list_members(%User{} = owner) do
    User
    |> where(team_owner_id: ^owner.id)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  @doc "Reads the owner fresh so a removed member loses the relationship immediately."
  def owner_for(%User{} = member) do
    User
    |> join(:inner, [member], owner in User, on: owner.id == member.team_owner_id)
    |> where([member], member.id == ^member.id)
    |> select([_member, owner], owner)
    |> Repo.one()
  end

  @doc "Whether a fresh membership row places this user under another owner."
  def member?(%User{} = user) do
    User
    |> where(id: ^user.id)
    |> where([user], not is_nil(user.team_owner_id))
    |> Repo.exists?()
  end

  @doc "Builds the stable, copyable URL carried by an invitation."
  def invitation_url(%Invitation{} = invitation) do
    SuperXWeb.Endpoint.url() <> "/team/invitations/" <> invitation.token
  end

  @doc "Looks up a bearer invitation for its public acceptance page."
  def get_invitation(token) when is_binary(token) do
    Invitation
    |> where(token: ^token)
    |> preload(:owner)
    |> Repo.one()
    |> case do
      nil -> nil
      invitation -> expire_if_needed(invitation)
    end
  end

  @doc "Accepts once, linking the signed-in user without sharing any of their data."
  def accept_invitation(%User{} = invitee, token) when is_binary(token) do
    Repo.transaction(fn ->
      invitation = locked_invitation(token)

      with {:ok, invitation} <- available_invitation(invitation),
           {:ok, owner, invitee} <- lock_membership_pair(invitation.owner_id, invitee.id),
           :ok <- valid_membership?(owner, invitee) do
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        membership_result =
          invitee
          |> membership_changeset(owner, invitation.email)
          |> Repo.update()

        case membership_result do
          {:ok, invitee} ->
            invitation
            |> Invitation.status_changeset("accepted", %{
              accepted_by_user_id: invitee.id,
              accepted_at: now
            })
            |> Repo.update!()

            {:ok, invitee}

          {:error, changeset} ->
            {:error, changeset}
        end
      end
    end)
    |> unwrap_transaction()
  end

  @doc "Revokes an unused invitation owned by the caller."
  def revoke_invitation(%User{} = owner, invitation_id) do
    Repo.transaction(fn ->
      invitation =
        Invitation
        |> where(id: ^invitation_id, owner_id: ^owner.id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case invitation do
        %Invitation{status: "pending"} ->
          invitation |> Invitation.status_changeset("revoked") |> Repo.update()

        _ ->
          {:error, :not_found}
      end
    end)
    |> unwrap_transaction()
  end

  @doc "Removes one of the caller's seats and leaves the member's account intact."
  def remove_member(%User{} = owner, member_id) do
    Repo.transaction(fn ->
      case lock_membership_pair(owner.id, member_id) do
        {:ok, locked_owner, %User{team_owner_id: owner_id} = member}
        when owner_id == locked_owner.id and is_nil(locked_owner.team_owner_id) ->
          member
          |> Ecto.Changeset.change(team_owner_id: nil)
          |> Repo.update()

        _ ->
          {:error, :not_found}
      end
    end)
    |> unwrap_transaction()
  end

  defp lock_owner(%User{} = owner) do
    case User |> where(id: ^owner.id) |> lock("FOR UPDATE") |> Repo.one() do
      %User{team_owner_id: nil} = owner -> {:ok, owner}
      %User{} -> {:error, :member_cannot_invite}
      nil -> {:error, :not_found}
    end
  end

  defp locked_invitation(token) do
    Invitation
    |> where(token: ^token)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp available_invitation(nil), do: {:error, :not_found}
  defp available_invitation(%Invitation{status: "accepted"}), do: {:error, :already_accepted}
  defp available_invitation(%Invitation{status: "revoked"}), do: {:error, :revoked}
  defp available_invitation(%Invitation{status: "expired"}), do: {:error, :expired}

  defp available_invitation(%Invitation{status: "pending"} = invitation) do
    if expired?(invitation) do
      invitation |> Invitation.status_changeset("expired") |> Repo.update!()
      {:error, :expired}
    else
      {:ok, invitation}
    end
  end

  defp lock_membership_pair(owner_id, invitee_id) do
    users =
      User
      |> where([user], user.id in ^Enum.uniq([owner_id, invitee_id]))
      |> order_by(asc: :id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    with %User{} = owner <- Enum.find(users, &(&1.id == owner_id)),
         %User{} = invitee <- Enum.find(users, &(&1.id == invitee_id)) do
      {:ok, owner, invitee}
    else
      _ -> {:error, :not_found}
    end
  end

  defp valid_membership?(%User{id: id}, %User{id: id}), do: {:error, :self_membership}

  defp valid_membership?(%User{team_owner_id: owner_id}, _invitee) when not is_nil(owner_id),
    do: {:error, :owner_is_member}

  defp valid_membership?(_owner, %User{team_owner_id: owner_id}) when not is_nil(owner_id),
    do: {:error, :already_member}

  defp valid_membership?(_owner, %User{} = invitee) do
    if Repo.exists?(from(user in User, where: user.team_owner_id == ^invitee.id)) do
      {:error, :invitee_owns_team}
    else
      :ok
    end
  end

  defp membership_changeset(invitee, owner, email) do
    invitee =
      if is_nil(invitee.email), do: Ecto.Changeset.change(invitee, email: email), else: invitee

    invitee
    |> Ecto.Changeset.change(team_owner_id: owner.id)
    |> Ecto.Changeset.unique_constraint(:email)
    |> Ecto.Changeset.check_constraint(:team_owner_id, name: :users_cannot_own_themselves)
  end

  defp expire_if_needed(%Invitation{status: "pending"} = invitation) do
    if expired?(invitation) do
      invitation |> Invitation.status_changeset("expired") |> Repo.update!()
    else
      invitation
    end
  end

  defp expire_if_needed(invitation), do: invitation

  defp expired?(invitation) do
    DateTime.compare(invitation.expires_at, DateTime.utc_now()) != :gt
  end

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp maybe_deliver(owner, invitation, url) do
    if Mailer.configured?() do
      owner
      |> InvitationEmail.build(invitation, url)
      |> Mailer.deliver()
      |> case do
        {:ok, _metadata} ->
          :ok

        {:error, reason} ->
          Logger.warning("Team invitation email was not delivered: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    error ->
      Logger.warning("Team invitation email was not delivered: #{Exception.message(error)}")
      :ok
  end
end
