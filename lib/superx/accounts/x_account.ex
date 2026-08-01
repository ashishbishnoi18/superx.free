defmodule SuperX.Accounts.XAccount do
  @moduledoc """
  A connected X account. Holds the OAuth2 tokens used for publishing and
  private DMs. Bulk public reads come from twitterapi.io instead.

  Tokens are encrypted at rest via `SuperX.Vault.EncryptedBinary`.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.User

  # Never let tokens reach a log line or an inspected struct.
  @derive {Inspect, except: [:access_token, :refresh_token]}
  schema "x_accounts" do
    belongs_to :user, User

    field :x_user_id, :string
    field :handle, :string
    field :display_name, :string
    field :avatar_url, :string
    field :description, :string

    field :followers_count, :integer, default: 0
    field :following_count, :integer, default: 0
    field :posts_count, :integer, default: 0

    field :access_token, SuperX.Vault.EncryptedBinary
    field :refresh_token, SuperX.Vault.EncryptedBinary
    field :token_expires_at, :utc_datetime
    field :scopes, {:array, :string}, default: []

    field :reauth_needed, :boolean, default: false
    field :reauth_reason, :string

    field :connected_at, :utc_datetime
    field :last_synced_at, :utc_datetime

    has_one :voice_profile, SuperX.Content.VoiceProfile
    has_many :schedule_slots, SuperX.Content.ScheduleSlot
    has_many :posts, SuperX.Content.Post
    has_many :content_workers, SuperX.Workers.ContentWorker
    has_many :dm_conversations, SuperX.DMs.Conversation
    has_many :dm_messages, SuperX.DMs.Message

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for the profile fields refreshed from X."
  def profile_changeset(x_account, attrs) do
    x_account
    |> cast(attrs, [
      :x_user_id,
      :handle,
      :display_name,
      :avatar_url,
      :description,
      :followers_count,
      :following_count,
      :posts_count,
      :last_synced_at
    ])
    |> validate_required([:x_user_id, :handle])
    |> unique_constraint(:x_user_id)
  end

  @doc "Changeset applied after a successful OAuth exchange or refresh."
  def token_changeset(x_account, attrs) do
    x_account
    |> cast(attrs, [:access_token, :refresh_token, :token_expires_at, :scopes, :connected_at])
    |> validate_required([:access_token])
    # A successful token write always clears a prior reauth flag.
    |> put_change(:reauth_needed, false)
    |> put_change(:reauth_reason, nil)
  end

  @doc "Flags the account as needing the user to reconnect it."
  def reauth_changeset(x_account, reason) do
    change(x_account, reauth_needed: true, reauth_reason: reason)
  end

  @doc """
  True when the access token is missing or within `skew` seconds of
  expiring. Used by the refresher and before every write.
  """
  def token_stale?(%__MODULE__{} = account, skew \\ 120) do
    cond do
      is_nil(account.access_token) -> true
      is_nil(account.token_expires_at) -> false
      true -> DateTime.diff(account.token_expires_at, DateTime.utc_now()) <= skew
    end
  end
end
