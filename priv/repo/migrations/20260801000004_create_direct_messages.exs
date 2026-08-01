defmodule SuperX.Repo.Migrations.CreateDirectMessages do
  use Ecto.Migration

  def change do
    create table(:dm_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      # The one-to-one send endpoint only needs the other user's id. The
      # conversation id arrives later, either from a read or the first send.
      add :x_conversation_id, :string
      add :participant_x_user_id, :string, null: false
      add :participant_handle, :citext
      add :participant_name, :string
      add :participant_avatar_url, :string

      # Kept on the conversation because the inbox should not load every
      # message merely to render fifty previews in order.
      add :last_message_text, :text
      add :last_message_at, :utc_datetime
      add :last_synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dm_conversations, [:x_account_id, :participant_x_user_id])

    create unique_index(:dm_conversations, [:x_account_id, :x_conversation_id],
             where: "x_conversation_id IS NOT NULL"
           )

    create index(:dm_conversations, [:x_account_id, :last_message_at])

    create table(:dm_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :conversation_id,
          references(:dm_conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :x_message_id, :string, null: false
      add :sender_x_user_id, :string, null: false
      add :direction, :string, null: false
      add :text, :text, null: false
      add :sent_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # Provider polling and write responses can overlap; X's event id is
    # the authority, so seeing it twice must update rather than duplicate.
    create unique_index(:dm_messages, [:x_account_id, :x_message_id])
    create index(:dm_messages, [:conversation_id, :sent_at])

    create constraint(:dm_messages, :direction_value,
             check: "direction IN ('inbound', 'outbound')"
           )
  end
end
