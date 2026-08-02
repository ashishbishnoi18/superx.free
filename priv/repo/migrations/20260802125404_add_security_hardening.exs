defmodule SuperX.Repo.Migrations.AddSecurityHardening do
  use Ecto.Migration

  def up do
    alter table(:x_accounts) do
      add :disconnected_at, :utc_datetime
    end

    create index(:x_accounts, [:user_id],
             where: "disconnected_at IS NULL",
             name: :x_accounts_connected_user_id_index
           )

    alter table(:posts) do
      # Optimistic locking makes an automation action a durable claim before
      # its external X side effect runs.
      add :automation_version, :integer, null: false, default: 1
    end

    create table(:media_assets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:media_assets, [:key])
    create index(:media_assets, [:user_id])
    create index(:media_assets, [:x_account_id])

    # Existing segment arrays only stored opaque keys. Recover their owners
    # before reads start enforcing the new authorization boundary.
    execute(backfill_media_assets("posts"))
    execute(backfill_media_assets("generations"))
  end

  def down do
    drop table(:media_assets)

    alter table(:posts) do
      remove :automation_version
    end

    drop index(:x_accounts, [:user_id], name: :x_accounts_connected_user_id_index)

    alter table(:x_accounts) do
      remove :disconnected_at
    end
  end

  defp backfill_media_assets(table) do
    """
    INSERT INTO media_assets (id, key, user_id, x_account_id, inserted_at, updated_at)
    SELECT DISTINCT ON (media.key)
      (
        substr(md5('superx.media:' || media.key), 1, 8) || '-' ||
        substr(md5('superx.media:' || media.key), 9, 4) || '-' ||
        substr(md5('superx.media:' || media.key), 13, 4) || '-' ||
        substr(md5('superx.media:' || media.key), 17, 4) || '-' ||
        substr(md5('superx.media:' || media.key), 21, 12)
      )::uuid,
      media.key,
      owner.user_id,
      owner.x_account_id,
      NOW(),
      NOW()
    FROM #{table} AS owner
    CROSS JOIN LATERAL unnest(owner.segments) AS segment(value)
    CROSS JOIN LATERAL jsonb_array_elements_text(
      COALESCE(segment.value->'media_ids', '[]'::jsonb)
    ) AS media(key)
    ON CONFLICT (key) DO NOTHING
    """
  end
end
