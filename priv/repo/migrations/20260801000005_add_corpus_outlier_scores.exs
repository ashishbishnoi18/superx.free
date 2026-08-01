defmodule SuperX.Repo.Migrations.AddCorpusOutlierScores do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE corpus_posts
      ADD COLUMN follower_bucket smallint
      GENERATED ALWAYS AS (
        CASE
          WHEN author_followers < 1000 THEN 0
          WHEN author_followers < 3162 THEN 1
          WHEN author_followers < 10000 THEN 2
          WHEN author_followers < 31623 THEN 3
          WHEN author_followers < 100000 THEN 4
          WHEN author_followers < 316228 THEN 5
          WHEN author_followers < 1000000 THEN 6
          WHEN author_followers < 3162278 THEN 7
          WHEN author_followers < 10000000 THEN 8
          ELSE 9
        END
      ) STORED
    """)

    create index(:corpus_posts, [:follower_bucket, :engagement_score],
             name: :corpus_posts_outlier_baseline_idx
           )

    create table(:corpus_outlier_baselines, primary_key: false) do
      add :follower_bucket, :smallint, primary_key: true
      add :median_engagement_score, :float, null: false
      add :sample_size, :bigint, null: false
    end

    execute("""
    INSERT INTO corpus_outlier_baselines
      (follower_bucket, median_engagement_score, sample_size)
    SELECT
      follower_bucket,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY engagement_score),
      count(*)
    FROM corpus_posts
    GROUP BY follower_bucket
    """)
  end

  def down do
    drop table(:corpus_outlier_baselines)

    drop index(:corpus_posts, [:follower_bucket, :engagement_score],
           name: :corpus_posts_outlier_baseline_idx
         )

    execute("ALTER TABLE corpus_posts DROP COLUMN follower_bucket")
  end
end
