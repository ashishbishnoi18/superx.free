defmodule SuperX.XChat.Identity do
  @moduledoc false

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.XAccount

  @derive {Inspect, except: [:private_key]}
  schema "xchat_identities" do
    belongs_to :x_account, XAccount

    field :private_key, SuperX.Vault.EncryptedBinary
    field :key_version, :string
    field :registration, :map
    field :registered_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(account, private_key, key_version, registration) do
    %__MODULE__{x_account_id: account.id}
    |> change(
      private_key: private_key,
      key_version: key_version,
      registration: registration
    )
    |> validate_required([:private_key, :key_version, :registration])
    |> unique_constraint(:x_account_id)
  end

  @doc false
  def registered_changeset(identity, registered_at) do
    change(identity, registered_at: registered_at)
  end
end
