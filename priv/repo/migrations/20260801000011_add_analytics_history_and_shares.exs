defmodule SuperX.Repo.Migrations.AddAnalyticsHistoryAndShares do
  use Ecto.Migration

  def change do
    alter table(:analytics_snapshots) do
      add :source, :string, null: false, default: "collected"

      # Imported exports do not always carry these lifetime totals. Keeping
      # the absence explicit prevents a daily post count being mistaken for
      # an account's lifetime count.
      modify :following, :integer, null: true, from: {:integer, null: false, default: 0}
      modify :posts, :integer, null: true, from: {:integer, null: false, default: 0}
    end

    create constraint(:analytics_snapshots, :analytics_snapshot_source,
             check: "source IN ('collected', 'imported')"
           )

    create table(:analytics_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :token, :string, null: false
      add :from_date, :date, null: false
      add :to_date, :date, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:analytics_shares, [:x_account_id])
    create unique_index(:analytics_shares, [:token])

    create constraint(:analytics_shares, :analytics_share_date_order,
             check: "from_date <= to_date"
           )
  end
end
