defmodule SuperX.Repo.Migrations.CreateSignals do
  use Ecto.Migration

  def change do
    # A standing watch on X: whose followers to check, which keywords to
    # track, which list to read. Each run scores whoever it finds against
    # the agent's own description of who it's looking for.
    create table(:signal_agents, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false

      # keyword | follower | profile | list
      add :kind, :string, null: false
      # What to watch: a search query, a handle, or a list id.
      add :target, :string, null: false

      # Natural language description of a good match. This is the whole
      # configuration surface — no filter builder, just a sentence.
      add :ideal_customer, :text

      # Matches below this are found but not kept.
      add :min_score, :integer, null: false, default: 60

      add :enabled, :boolean, null: false, default: true
      add :last_run_at, :utc_datetime
      add :last_error, :string

      # Running totals, for the agent list.
      add :leads_found, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:signal_agents, [:x_account_id, :enabled])
    create index(:signal_agents, [:enabled, :last_run_at])
    create constraint(:signal_agents, :min_score_range, check: "min_score between 0 and 100")

    # A person an agent found and thought was worth keeping.
    create table(:leads, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :signal_agent_id, references(:signal_agents, type: :binary_id, on_delete: :nilify_all)

      add :x_user_id, :string
      add :handle, :citext, null: false
      add :display_name, :string
      add :avatar_url, :string
      add :bio, :text
      add :location, :string

      add :followers_count, :integer, null: false, default: 0
      add :following_count, :integer, null: false, default: 0
      add :verified, :boolean, null: false, default: false

      # Why the agent kept them.
      add :score, :integer
      add :reason, :text
      # The post that surfaced them, when a keyword watch found them.
      add :source_post_id, :string
      add :source_post_text, :text

      # new | contacted | replied | won | archived
      add :status, :string, null: false, default: "new"
      add :notes, :text
      add :contacted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # One row per person per account — re-running a watch updates, not
    # duplicates.
    create unique_index(:leads, [:x_account_id, :handle])
    create index(:leads, [:x_account_id, :status, :score])
    create index(:leads, [:signal_agent_id])
  end
end
