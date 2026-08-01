defmodule SuperX.Repo.Migrations.CreateBillingAndAnalytics do
  use Ecto.Migration

  def change do
    create table(:subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :provider, :string, null: false, default: "stripe"
      add :provider_customer_id, :string
      add :provider_subscription_id, :string
      add :provider_price_id, :string

      # free | pro | advanced | ultra
      add :tier, :string, null: false, default: "free"
      # trialing | active | past_due | canceled | paused
      add :status, :string, null: false, default: "active"

      add :amount_cents, :integer
      add :currency, :string, size: 3
      # month | year
      add :interval, :string

      add :trial_ends_at, :utc_datetime
      add :current_period_end, :utc_datetime
      add :cancel_at_period_end, :boolean, null: false, default: false
      add :canceled_at, :utc_datetime

      add :card_brand, :string
      add :card_last4, :string, size: 4

      timestamps(type: :utc_datetime)
    end

    # One active subscription row per user.
    create unique_index(:subscriptions, [:user_id])

    create unique_index(:subscriptions, [:provider_subscription_id],
             where: "provider_subscription_id IS NOT NULL"
           )

    create index(:subscriptions, [:provider_customer_id])

    # Append-only credit history. The ledger is the source of truth;
    # `quotas` holds the fast-path counter.
    create table(:credit_ledger, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      # Negative to spend, positive to grant.
      add :delta, :integer, null: false
      add :balance_after, :integer, null: false

      # generation | ask | reply_draft | monthly_grant | purchase | refund
      add :reason, :string, null: false
      add :ref_type, :string
      add :ref_id, :binary_id
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:credit_ledger, [:user_id, :inserted_at])

    # Rolling quota windows: credits_month, posts_month, replies_day, leads_day.
    create table(:quotas, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :key, :string, null: false
      add :used, :integer, null: false, default: 0
      add :limit, :integer, null: false, default: 0
      add :window_start, :utc_datetime, null: false
      add :window_end, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:quotas, [:user_id, :key])

    # Daily per-account metrics powering the analytics dashboard.
    create table(:analytics_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :date, :date, null: false

      add :followers, :integer, null: false, default: 0
      add :following, :integer, null: false, default: 0
      add :posts, :integer, null: false, default: 0

      add :impressions, :integer, null: false, default: 0
      add :engagements, :integer, null: false, default: 0
      add :likes, :integer, null: false, default: 0
      add :replies, :integer, null: false, default: 0
      add :reposts, :integer, null: false, default: 0
      add :profile_clicks, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:analytics_snapshots, [:x_account_id, :date])
    create index(:analytics_snapshots, [:date])
  end
end
