defmodule SuperX.Repo.Migrations.CreateChats do
  use Ecto.Migration

  def change do
    create table(:chats, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      # Derived from the opening message so the list is readable.
      add :title, :string

      timestamps(type: :utc_datetime)
    end

    create index(:chats, [:user_id, :updated_at])

    create table(:chat_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :chat_id, references(:chats, type: :binary_id, on_delete: :delete_all), null: false

      # user | assistant
      add :role, :string, null: false
      add :content, :text, null: false

      # What the assistant did on this turn, for the "it acted" trail.
      # [%{"name" => "schedule_post", "summary" => "Queued for Mon 10:00"}]
      add :tool_calls, {:array, :map}, null: false, default: []

      add :credits_cost, :integer, null: false, default: 0

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:chat_messages, [:chat_id, :inserted_at])
  end
end
