defmodule SuperX.Repo.Migrations.AddStyleNotesToVoiceProfiles do
  use Ecto.Migration

  def change do
    alter table(:voice_profiles) do
      # Derived mechanics — sentence length, capitalisation, emoji use.
      # Kept apart from `about` so regenerating the voice doesn't discard
      # the user's hand-written `rules`.
      add :style_notes, :text
    end
  end
end
