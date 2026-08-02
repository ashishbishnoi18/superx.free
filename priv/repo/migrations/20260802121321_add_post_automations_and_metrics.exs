defmodule SuperX.Repo.Migrations.AddPostAutomationsAndMetrics do
  use Ecto.Migration

  def change do
    alter table(:posts) do
      # superx.so-style post automations. Each field is nil until the user
      # arms that automation; nil means "do nothing", never zero hours.
      add :auto_retweet_hours, :integer
      add :auto_retweet_undo_hours, :integer
      add :auto_plug_likes, :integer
      add :auto_plug_text, :text
      add :auto_delete_min_views, :integer
      add :auto_delete_hours, :integer

      # Which automations have already fired for this post, so a worker
      # re-run acts once rather than retweeting on every tick.
      add :automation_state, :map, null: false, default: %{}

      # Last fetched X metrics (views, likes, ...) for automations that
      # gate on performance, and when they were fetched.
      add :metrics, :map, null: false, default: %{}
      add :metrics_updated_at, :utc_datetime
    end

    alter table(:engagements) do
      # Views drive automations like auto-delete-below-N; likes alone are
      # not a reach signal.
      add :views, :integer, null: false, default: 0
    end
  end
end
