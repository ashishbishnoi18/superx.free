defmodule SuperX.Repo.Migrations.AddArticlePublishingFields do
  use Ecto.Migration

  def up do
    alter table(:articles) do
      add :x_post_id, :string
      add :publish_error, :text
    end

    create unique_index(:articles, [:x_post_id], where: "x_post_id IS NOT NULL")

    drop constraint(:articles, :valid_status)

    create constraint(:articles, :valid_status,
             check: "status IN ('draft', 'ready', 'publishing', 'published')"
           )
  end

  def down do
    drop constraint(:articles, :valid_status)

    create constraint(:articles, :valid_status,
             check: "status IN ('draft', 'ready', 'published')"
           )

    drop index(:articles, [:x_post_id])

    alter table(:articles) do
      remove :x_post_id
      remove :publish_error
    end
  end
end
