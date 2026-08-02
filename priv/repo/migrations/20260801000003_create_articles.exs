defmodule SuperX.Repo.Migrations.CreateArticles do
  use Ecto.Migration

  def change do
    create table(:articles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :x_account_id, references(:x_accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :text
      add :body, :text, null: false, default: ""
      add :status, :string, null: false, default: "draft"

      # Publication identifiers come only from X, not from editable form
      # params, so the composer cannot manufacture a published record.
      add :published_at, :utc_datetime
      add :x_article_id, :string
      add :permalink, :text

      add :word_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:articles, [:x_account_id, :status, :updated_at])
    create index(:articles, [:user_id])
    create unique_index(:articles, [:x_article_id], where: "x_article_id IS NOT NULL")

    create constraint(:articles, :valid_status,
             check: "status IN ('draft', 'ready', 'published')"
           )

    create constraint(:articles, :non_negative_word_count, check: "word_count >= 0")

    create constraint(:articles, :published_articles_have_a_destination,
             check:
               "status <> 'published' OR (published_at IS NOT NULL AND " <>
                 "(x_article_id IS NOT NULL OR permalink IS NOT NULL))"
           )
  end
end
