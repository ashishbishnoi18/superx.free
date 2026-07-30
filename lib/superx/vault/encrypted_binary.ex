defmodule SuperX.Vault.EncryptedBinary do
  @moduledoc """
  Ecto type that transparently encrypts a string into a `:binary` column.

  Schemas declare `field :access_token, SuperX.Vault.EncryptedBinary` and
  work with plaintext; the ciphertext never leaves the database layer.

  Note this is deliberately not searchable. Anything needing a lookup
  (session tokens) stores a hash instead — see `SuperX.Accounts.Session`.
  """

  use Ecto.Type

  @impl true
  def type, do: :binary

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(value) when is_binary(value), do: {:ok, SuperX.Vault.encrypt(value)}
  def dump(_), do: :error

  @impl true
  def load(nil), do: {:ok, nil}

  def load(value) when is_binary(value) do
    case SuperX.Vault.decrypt(value) do
      {:ok, plaintext} -> {:ok, plaintext}
      # A row we cannot decrypt is treated as absent rather than crashing
      # the query — the account is then flagged for reauth.
      :error -> {:ok, nil}
    end
  end
end
