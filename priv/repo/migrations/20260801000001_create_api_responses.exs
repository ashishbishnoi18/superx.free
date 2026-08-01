defmodule SuperX.Repo.Migrations.CreateApiResponses do
  use Ecto.Migration

  def change do
    # Every paid upstream response, kept permanently.
    #
    # Two jobs. It stops us paying twice for a call we already made, and
    # it is the only record of what the reads actually cost — the provider
    # bills per record, so `record_count` summed over a month is the bill.
    #
    # Rows are never deleted on expiry. A stale row still answers "did we
    # already buy this, and what did it say", which is worth more than the
    # disk it occupies.
    create table(:api_responses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :provider, :string, null: false
      add :path, :string, null: false

      # Digest of the canonicalised params. The params themselves are kept
      # alongside it so a row can be read without reversing the hash.
      add :params_hash, :string, null: false
      add :params, :map, null: false, default: %{}

      add :body, :map, null: false
      add :record_count, :integer, null: false, default: 0

      add :fetched_at, :utc_datetime_usec, null: false
      add :hit_count, :integer, null: false, default: 0
      add :last_hit_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # One row per distinct call. Refetching after the freshness window
    # overwrites it, so the table holds the newest answer per call rather
    # than growing without bound.
    create unique_index(:api_responses, [:provider, :path, :params_hash])

    # For the spend report.
    create index(:api_responses, [:provider, :fetched_at])
  end
end
