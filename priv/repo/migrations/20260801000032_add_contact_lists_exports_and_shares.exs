defmodule SuperX.Repo.Migrations.AddContactListsExportsAndShares do
  use Ecto.Migration

  def up do
    create table(:contact_lists, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :citext, null: false

      # `followers` is editable but cannot be deleted; `engage` is a live
      # view over CRM state. Giving them distinct kinds keeps those promises
      # in the data model instead of relying on their English names.
      add :kind, :string, null: false, default: "manual"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:contact_lists, [:x_account_id, :name])
    create unique_index(:contact_lists, [:x_account_id, :kind], where: "kind <> 'manual'")

    create constraint(:contact_lists, :contact_list_kind,
             check: "kind IN ('manual', 'followers', 'engage')"
           )

    create table(:contact_list_memberships, primary_key: false) do
      add :contact_list_id,
          references(:contact_lists, type: :binary_id, on_delete: :delete_all),
          primary_key: true,
          null: false

      add :lead_id, references(:leads, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:contact_list_memberships, [:lead_id])

    alter table(:signal_agents) do
      add :contact_list_id,
          references(:contact_lists, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:signal_agents, [:contact_list_id])

    create table(:contact_list_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :contact_list_id,
          references(:contact_lists, type: :binary_id, on_delete: :delete_all),
          null: false

      add :token, :string, null: false
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:contact_list_shares, [:contact_list_id])
    create unique_index(:contact_list_shares, [:token])

    execute("""
    INSERT INTO contact_lists (id, x_account_id, name, kind, inserted_at, updated_at)
    SELECT gen_random_uuid(), id, 'Followers', 'followers', NOW(), NOW()
    FROM x_accounts
    """)

    execute("""
    INSERT INTO contact_lists (id, x_account_id, name, kind, inserted_at, updated_at)
    SELECT gen_random_uuid(), id, 'Engage', 'engage', NOW(), NOW()
    FROM x_accounts
    """)

    # Existing agents keep their old behaviour and gain a concrete filing
    # destination; no lead found after deployment falls between two models.
    execute("""
    UPDATE signal_agents AS agent
    SET contact_list_id = list.id
    FROM contact_lists AS list
    WHERE list.x_account_id = agent.x_account_id
      AND list.kind = 'followers'
    """)

    # A deployment boundary should not decide whether an agent's contact
    # appears in its destination. Backfilling through the same agent link
    # gives earlier discoveries the filing rule their agent now carries.
    execute("""
    INSERT INTO contact_list_memberships
      (contact_list_id, lead_id, inserted_at, updated_at)
    SELECT agent.contact_list_id, lead.id, NOW(), NOW()
    FROM leads AS lead
    JOIN signal_agents AS agent ON agent.id = lead.signal_agent_id
    WHERE agent.contact_list_id IS NOT NULL
    ON CONFLICT (contact_list_id, lead_id) DO NOTHING
    """)
  end

  def down do
    drop table(:contact_list_shares)

    alter table(:signal_agents) do
      remove :contact_list_id
    end

    drop table(:contact_list_memberships)
    drop table(:contact_lists)
  end
end
