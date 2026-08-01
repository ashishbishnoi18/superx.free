defmodule SuperX.Repo.Migrations.VoiceCreatorInspirationAndReplySettings do
  use Ecto.Migration

  def change do
    # The old name made imitation sound intentional. Existing handles stay
    # useful, but are now treated only as sources of ideas.
    rename table(:voice_profiles), :favorite_voices, to: :inspiration_handles

    alter table(:voice_profiles) do
      add :reply_length, :string
      add :reply_question_policy, :string
    end

    create constraint(:voice_profiles, :reply_length_value,
             check: "reply_length IS NULL OR reply_length IN ('short', 'medium', 'long')"
           )

    create constraint(:voice_profiles, :reply_question_policy_value,
             check: "reply_question_policy IS NULL OR reply_question_policy IN ('ask', 'never')"
           )
  end
end
