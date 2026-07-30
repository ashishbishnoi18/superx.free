defmodule SuperX.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 12)

  # Leaving the default `version: 1` intact keeps prior migration
  # versions available for a stepwise rollback.
  def down, do: Oban.Migration.down(version: 1)
end
