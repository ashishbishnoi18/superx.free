defmodule SuperX.Repo.Migrations.EnableExtensions do
  use Ecto.Migration

  def up do
    # Semantic retrieval over the viral-post corpus.
    execute "CREATE EXTENSION IF NOT EXISTS vector"
    # Fuzzy handle/keyword matching in search.
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"
    # Case-insensitive emails and handles.
    execute "CREATE EXTENSION IF NOT EXISTS citext"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS citext"
    execute "DROP EXTENSION IF EXISTS pg_trgm"
    execute "DROP EXTENSION IF EXISTS vector"
  end
end
