defmodule SuperX.Repo.Migrations.AddXchatIdentitiesAndEncryptedConversations do
  use Ecto.Migration

  def change do
    create table(:xchat_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :private_key, :binary, null: false
      add :key_version, :string, null: false
      add :registration, :map, null: false
      add :registered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:xchat_identities, [:x_account_id])

    alter table(:dm_conversations) do
      add :encrypted, :boolean, null: false, default: false
    end
  end
end
