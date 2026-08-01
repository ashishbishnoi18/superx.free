defmodule SuperX.Repo.Migrations.AddTeams do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :team_owner_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:users, [:team_owner_id])

    create constraint(:users, :users_cannot_own_themselves,
             check: "team_owner_id IS NULL OR team_owner_id <> id"
           )

    create table(:team_invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :accepted_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :email, :citext, null: false
      add :token, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime, null: false
      add :accepted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:team_invitations, [:token])
    create index(:team_invitations, [:owner_id, :status])
    create index(:team_invitations, [:email])

    create constraint(:team_invitations, :team_invitations_status,
             check: "status IN ('pending', 'accepted', 'revoked', 'expired')"
           )
  end
end
