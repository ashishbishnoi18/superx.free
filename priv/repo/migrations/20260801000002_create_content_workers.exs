defmodule SuperX.Repo.Migrations.CreateContentWorkers do
  use Ecto.Migration

  def change do
    create table(:content_workers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false

      add :topic_source, :string, null: false
      add :product_context, :text

      add :batch_size, :integer, null: false, default: 3
      add :enabled, :boolean, null: false, default: true

      # Local-time cadence, deliberately the same primitive as publishing
      # slots rather than a cron expression supplied by the user.
      add :cadence, :string
      add :schedule_day, :integer
      add :schedule_time, :time

      add :last_run_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:content_workers, [:x_account_id, :inserted_at])
    create index(:content_workers, [:user_id])

    # This scan runs every minute, so rows that cannot be due stay out of it.
    create index(:content_workers, [:enabled, :cadence], where: "enabled AND cadence IS NOT NULL")

    create constraint(:content_workers, :content_workers_topic_source,
             check: "topic_source IN ('products', 'voice', 'trends')"
           )

    create constraint(:content_workers, :content_workers_batch_size,
             check: "batch_size BETWEEN 1 AND 20"
           )

    create constraint(:content_workers, :content_workers_product_context,
             check: "topic_source <> 'products' OR NULLIF(BTRIM(product_context), '') IS NOT NULL"
           )

    create constraint(:content_workers, :content_workers_schedule,
             check: """
             (cadence IS NULL AND schedule_day IS NULL AND schedule_time IS NULL)
             OR (cadence = 'daily' AND schedule_day IS NULL AND schedule_time IS NOT NULL)
             OR (cadence = 'weekly' AND schedule_day BETWEEN 0 AND 6 AND schedule_time IS NOT NULL)
             """
           )
  end
end
