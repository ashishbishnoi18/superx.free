defmodule SuperX.Repo.Migrations.CreateContent do
  use Ecto.Migration

  def change do
    # The learned writing voice for one account. Regenerated on demand.
    create table(:voice_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      # First-person summary of who the account is.
      add :about, :text
      # Comma-separated subject areas used to steer corpus retrieval.
      add :topics, :text
      # Prompts the writer uses to find something to say.
      add :questions, {:array, :text}, null: false, default: []
      # Freeform user-authored style rules, always appended to the prompt.
      add :rules, :text

      # Handles whose style should be imitated.
      add :favorite_voices, {:array, :string}, null: false, default: []
      # Feed the account's own posts in as few-shot examples.
      add :use_own_posts, :boolean, null: false, default: true

      # Which posts the profile was derived from, for regeneration diffs.
      add :source_post_ids, {:array, :string}, null: false, default: []
      add :generated_at, :utc_datetime
      add :version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:voice_profiles, [:x_account_id])

    # Recurring weekly publishing slots. Posts fill the next open one.
    create table(:schedule_slots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      # 0 = Sunday .. 6 = Saturday, in the user's timezone.
      add :day_of_week, :integer, null: false
      add :time, :time, null: false
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:schedule_slots, [:x_account_id, :day_of_week, :time])
    create constraint(:schedule_slots, :day_of_week_range, check: "day_of_week between 0 and 6")

    # Every post the app knows about, in any lifecycle state.
    create table(:posts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      # draft | scheduled | publishing | posted | failed | cancelled
      add :status, :string, null: false, default: "draft"

      # A thread is an ordered list of segments; a single post has one.
      add :segments, {:array, :map}, null: false, default: []

      add :scheduled_at, :utc_datetime
      add :published_at, :utc_datetime

      # Resulting X ids, one per segment, in order.
      add :x_post_ids, {:array, :string}, null: false, default: []
      add :permalink, :string

      # Failure surface for the Failed tab.
      add :error, :text
      add :failed_at, :utc_datetime
      add :attempt_count, :integer, null: false, default: 0

      # manual | generated | reply
      add :source, :string, null: false, default: "manual"
      # Set when the post came off the Ready to Post shelf.
      add :generation_id, :binary_id

      # Replying to an existing X post.
      add :reply_to_x_post_id, :string

      add :tags, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create index(:posts, [:x_account_id, :status])
    create index(:posts, [:user_id])
    # The dispatcher scans this every minute; keep it tight.
    create index(:posts, [:scheduled_at], where: "status = 'scheduled'")
    create index(:posts, [:x_account_id, :published_at])

    # The viral-post library. Shared across all users — this is the moat.
    create table(:corpus_posts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :x_post_id, :string, null: false
      add :author_handle, :citext, null: false
      add :author_name, :string
      add :author_avatar_url, :string
      add :author_followers, :integer, null: false, default: 0
      add :author_verified, :boolean, null: false, default: false

      add :text, :text, null: false
      add :lang, :string, size: 8

      add :likes, :integer, null: false, default: 0
      add :reposts, :integer, null: false, default: 0
      add :replies, :integer, null: false, default: 0
      add :quotes, :integer, null: false, default: 0
      add :bookmarks, :integer, null: false, default: 0
      add :impressions, :integer, null: false, default: 0

      # Engagement normalised against author reach, so small accounts
      # with genuinely viral posts aren't buried by big-account noise.
      add :engagement_score, :float, null: false, default: 0.0

      add :posted_at, :utc_datetime, null: false

      add :media, {:array, :map}, null: false, default: []
      add :has_media, :boolean, null: false, default: false
      add :is_thread, :boolean, null: false, default: false

      # Classifier output used to match a post to a user's interests.
      add :topics, {:array, :string}, null: false, default: []

      add :embedding, :vector, size: 1024

      add :source, :string, null: false, default: "scraper"
      add :ingested_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:corpus_posts, [:x_post_id])
    create index(:corpus_posts, [:engagement_score])
    create index(:corpus_posts, [:posted_at])
    create index(:corpus_posts, [:author_handle])
    create index(:corpus_posts, [:topics], using: :gin)

    # Full-text search column, maintained by Postgres.
    execute(
      """
      ALTER TABLE corpus_posts
        ADD COLUMN search tsvector
        GENERATED ALWAYS AS (to_tsvector('english', coalesce(text, ''))) STORED
      """,
      "ALTER TABLE corpus_posts DROP COLUMN search"
    )

    create index(:corpus_posts, [:search], using: :gin)

    # Semantic retrieval. HNSW over cosine distance.
    execute(
      "CREATE INDEX corpus_posts_embedding_idx ON corpus_posts USING hnsw (embedding vector_cosine_ops)",
      "DROP INDEX corpus_posts_embedding_idx"
    )

    # AI-written posts sitting on the Ready to Post shelf.
    create table(:generations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :segments, {:array, :map}, null: false, default: []

      # for_you | products | trending | media | viral
      add :kind, :string, null: false, default: "for_you"
      # shelf | used | dismissed
      add :status, :string, null: false, default: "shelf"

      # Attribution for the "Inspired by a post with N likes" label.
      add :source_corpus_post_id,
          references(:corpus_posts, type: :binary_id, on_delete: :nilify_all)

      add :source_likes, :integer

      add :model, :string
      add :prompt_version, :integer, null: false, default: 1
      add :credits_cost, :integer, null: false, default: 0
      add :score, :float

      timestamps(type: :utc_datetime)
    end

    create index(:generations, [:x_account_id, :status, :kind])
    create index(:generations, [:user_id])

    # Posts link back to the shelf item they came from.
    alter table(:posts) do
      modify :generation_id,
             references(:generations, type: :binary_id, on_delete: :nilify_all),
             from: :binary_id
    end
  end
end
