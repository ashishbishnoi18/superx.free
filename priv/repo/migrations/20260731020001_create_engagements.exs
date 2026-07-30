defmodule SuperX.Repo.Migrations.CreateEngagements do
  use Ecto.Migration

  def change do
    # Something on X that is waiting on a response: a mention, a reply to
    # one of your posts, or a post surfaced from a topic feed.
    create table(:engagements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      # mention | reply | feed
      add :kind, :string, null: false
      # open | replied | ignored
      add :status, :string, null: false, default: "open"

      add :x_post_id, :string, null: false
      add :conversation_id, :string
      # The post of yours this is responding to, when there is one.
      add :in_reply_to_x_post_id, :string

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

      add :posted_at, :utc_datetime, null: false

      # How worth answering this looks, 0-100. Written by the scorer so the
      # inbox can lead with what matters instead of what is newest.
      add :priority, :integer
      add :priority_reason, :string

      # Our reply, once one exists.
      add :replied_post_id, references(:posts, type: :binary_id, on_delete: :nilify_all)
      add :replied_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # One row per post per account — re-polling must update, not duplicate.
    create unique_index(:engagements, [:x_account_id, :x_post_id])
    create index(:engagements, [:x_account_id, :kind, :status])
    create index(:engagements, [:x_account_id, :status, :priority])
    create index(:engagements, [:posted_at])

    # A drafted reply waiting for approval. Kept apart from `posts` for the
    # same reason generations are: the shelf can be refilled and discarded
    # without touching the user's real drafts.
    create table(:reply_drafts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :engagement_id, references(:engagements, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :text, :text, null: false
      # shelf | used | dismissed
      add :status, :string, null: false, default: "shelf"

      add :model, :string
      add :credits_cost, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:reply_drafts, [:engagement_id, :status])

    # Topic feeds the user follows for discovery.
    create table(:feeds, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :query, :string, null: false
      add :min_likes, :integer, null: false, default: 50
      add :enabled, :boolean, null: false, default: true
      add :last_synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:feeds, [:x_account_id, :query])
    create index(:feeds, [:enabled])

    # Where a feed engagement came from, so the inbox can group by feed.
    alter table(:engagements) do
      add :feed_id, references(:feeds, type: :binary_id, on_delete: :delete_all)
    end

    create index(:engagements, [:feed_id])
  end
end
