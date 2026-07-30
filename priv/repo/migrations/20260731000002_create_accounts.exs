defmodule SuperX.Repo.Migrations.CreateAccounts do
  use Ecto.Migration

  def change do
    # The billing/login entity. One user may drive several X accounts.
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext
      add :name, :string
      add :avatar_url, :string
      add :timezone, :string, null: false, default: "Etc/UTC"

      # UI preferences mirroring what the reference app keeps in /api/me.
      add :settings, :map, null: false, default: %{}

      add :onboarding_completed_at, :utc_datetime
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email], where: "email IS NOT NULL")

    # A connected X account. Access tokens are encrypted at rest.
    create table(:x_accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :x_user_id, :string, null: false
      add :handle, :citext, null: false
      add :display_name, :string
      add :avatar_url, :string
      add :description, :text

      add :followers_count, :integer, null: false, default: 0
      add :following_count, :integer, null: false, default: 0
      add :posts_count, :integer, null: false, default: 0

      add :access_token, :binary
      add :refresh_token, :binary
      add :token_expires_at, :utc_datetime
      add :scopes, {:array, :string}, null: false, default: []

      # Set when refresh fails, so the UI can nag for reconnection.
      add :reauth_needed, :boolean, null: false, default: false
      add :reauth_reason, :string

      add :connected_at, :utc_datetime
      add :last_synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # An X account connects to exactly one user.
    create unique_index(:x_accounts, [:x_user_id])
    create index(:x_accounts, [:user_id])
    create index(:x_accounts, [:token_expires_at], where: "refresh_token IS NOT NULL")

    # Which account the user is currently acting as.
    alter table(:users) do
      add :default_x_account_id, references(:x_accounts, type: :binary_id, on_delete: :nilify_all)
    end

    # Short-lived OAuth state for the PKCE handshake.
    create table(:oauth_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :state, :string, null: false
      add :code_verifier, :string, null: false
      # Set when connecting an extra account to an existing session.
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :redirect_to, :string
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_requests, [:state])
    create index(:oauth_requests, [:expires_at])

    # Browser sessions, so tokens can be revoked server-side.
    create table(:user_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :user_agent, :string
      add :ip, :string
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:user_sessions, [:token_hash])
    create index(:user_sessions, [:user_id])
  end
end
