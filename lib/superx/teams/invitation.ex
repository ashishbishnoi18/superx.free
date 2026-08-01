defmodule SuperX.Teams.Invitation do
  @moduledoc """
  A bearer invitation into one owner's billing entitlement.

  The token remains recoverable because self-hosted installations may not
  deliver mail: the owner must always be able to copy the same link later.
  Acceptance is made single-use by locking this row before its status changes.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.User

  @statuses ~w(pending accepted revoked expired)
  @token_bytes 32
  @ttl_days 7

  @derive {Inspect, except: [:token]}
  schema "team_invitations" do
    belongs_to :owner, User
    belongs_to :accepted_by_user, User

    field :email, :string
    field :token, :string
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Builds a seven-day invitation with enough entropy to use as a bearer link."
  def build(%User{} = owner, attrs) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@ttl_days, :day)
      |> DateTime.truncate(:second)

    %__MODULE__{
      owner_id: owner.id,
      token: random_token(),
      expires_at: attrs[:expires_at] || attrs["expires_at"] || expires_at
    }
    |> changeset(attrs)
  end

  @doc false
  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:email, :token, :expires_at, :owner_id])
    |> validate_length(:email, max: 320)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> unique_constraint(:token)
    |> check_constraint(:status, name: :team_invitations_status)
  end

  @doc false
  def status_changeset(invitation, status, attrs \\ %{}) when status in @statuses do
    invitation
    |> change(Map.put(attrs, :status, status))
    |> check_constraint(:status, name: :team_invitations_status)
  end

  defp random_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
