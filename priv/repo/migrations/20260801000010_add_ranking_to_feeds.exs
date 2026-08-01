defmodule SuperX.Repo.Migrations.AddRankingToFeeds do
  use Ecto.Migration

  def change do
    alter table(:feeds) do
      add :ranking, :string, null: false, default: "relevance"
    end

    create constraint(:feeds, :feeds_ranking_check, check: "ranking IN ('relevance', 'newest')")
  end
end
