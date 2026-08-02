defmodule SuperX.Repo.Migrations.UpgradeObanToV14 do
  @moduledoc """
  Oban 2.23 ships schema version 14; this repo pinned 12 when the jobs table
  was created and never moved. Version 14 adds `suspended` to the job state
  enum, so the running library had a state it could write and the database
  would reject. Version 13 adds the cancelled and discarded indexes its
  pruning queries expect.
  """

  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)

  # Back down to 12, not 1: the table predates this migration and dropping it
  # would take every queued job with it.
  def down, do: Oban.Migration.down(version: 12)
end
