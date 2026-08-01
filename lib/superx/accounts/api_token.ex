defmodule SuperX.Accounts.ApiToken do
  @moduledoc """
  A revocable credential for the read-only API.

  The database keeps a short random identifier for lookup and a hash of a
  separately generated secret. Keeping those pieces independent means the
  readable prefix does not reduce the secret's entropy, while a database
  leak still cannot be turned into an authenticated request.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.User

  @prefix_bytes 9
  @secret_bytes 32
  @marker "sx_"

  @derive {Inspect, except: [:token_hash]}
  schema "api_tokens" do
    belongs_to :user, User

    field :name, :string
    field :token_prefix, :string
    field :token_hash, :binary
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Builds a token and the changeset that stores it.

  The plaintext is returned once to the caller and never placed on the
  schema, where an inspected struct could accidentally expose it.
  """
  def build(%User{} = user, attrs) do
    prefix = @marker <> random(@prefix_bytes)
    secret = random(@secret_bytes)

    changeset =
      %__MODULE__{
        user_id: user.id,
        token_prefix: prefix,
        token_hash: hash(secret)
      }
      |> changeset(attrs)

    {prefix <> "." <> secret, changeset}
  end

  @doc "Parses a presented token into its lookup prefix and secret."
  def split(encoded) when is_binary(encoded) do
    with [prefix, secret] <- String.split(encoded, ".", parts: 2),
         true <- String.starts_with?(prefix, @marker),
         false <- secret == "" do
      {:ok, prefix, secret}
    else
      _ -> :error
    end
  end

  def split(_encoded), do: :error

  @doc "Compares a presented secret without leaking a useful timing signal."
  def secret_matches?(%__MODULE__{token_hash: stored}, secret) when is_binary(secret) do
    Plug.Crypto.secure_compare(stored, hash(secret))
  end

  @doc false
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
    |> unique_constraint(:token_prefix)
  end

  @doc false
  def revoke_changeset(api_token) do
    change(api_token, revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp hash(secret), do: :crypto.hash(:sha256, secret)
end
