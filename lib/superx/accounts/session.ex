defmodule SuperX.Accounts.Session do
  @moduledoc """
  A browser session. The cookie carries a random token; only its SHA-256
  hash is stored, so a database leak does not yield usable sessions.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.User

  @rand_size 32
  @default_validity_days 60

  @derive {Inspect, except: [:token_hash]}
  schema "user_sessions" do
    belongs_to :user, User

    field :token_hash, :binary
    field :user_agent, :string
    field :ip, :string
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Builds a session for `user`, returning the plaintext token to put in
  the cookie alongside the struct to insert. The plaintext is never
  persisted.
  """
  def build(%User{} = user, attrs \\ %{}) do
    token = :crypto.strong_rand_bytes(@rand_size)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@default_validity_days * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    session =
      %__MODULE__{
        user_id: user.id,
        token_hash: hash(token),
        user_agent: attrs[:user_agent],
        ip: attrs[:ip],
        expires_at: expires_at
      }

    {Base.url_encode64(token, padding: false), session}
  end

  @doc "Hashes a raw session token for lookup."
  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc "Decodes a cookie value back into the raw token bytes."
  def decode(encoded) when is_binary(encoded), do: Base.url_decode64(encoded, padding: false)
  def decode(_), do: :error

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:user_agent, :ip, :expires_at])
    |> validate_required([:expires_at])
  end
end
