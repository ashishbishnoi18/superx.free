defmodule SuperX.Content.VoiceProfileTest do
  use ExUnit.Case, async: true

  alias SuperX.Content.VoiceProfile

  test "normalises creator handles without accepting more than three" do
    profile = %VoiceProfile{}

    changeset =
      VoiceProfile.changeset(profile, %{
        x_account_id: Ecto.UUID.generate(),
        inspiration_handles: [
          " @paulg ",
          "https://x.com/shl/status/123",
          "twitter.com/levelsio",
          "fourth"
        ]
      })

    refute changeset.valid?
    assert %{inspiration_handles: ["should have at most 3 item(s)"]} = errors_on(changeset)

    valid =
      VoiceProfile.changeset(profile, %{
        x_account_id: Ecto.UUID.generate(),
        inspiration_handles: [" @paulg ", "https://x.com/shl/status/123", "@paulg"]
      })

    assert Ecto.Changeset.get_change(valid, :inspiration_handles) == ["paulg", "shl"]
  end

  test "rejects settings the reply prompt does not implement" do
    changeset =
      VoiceProfile.changeset(%VoiceProfile{}, %{
        x_account_id: Ecto.UUID.generate(),
        reply_length: "epic",
        reply_question_policy: "occasionally"
      })

    refute changeset.valid?

    assert %{
             reply_length: ["is invalid"],
             reply_question_policy: ["is invalid"]
           } = errors_on(changeset)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.fetch!(String.to_existing_atom(key)) |> to_string()
      end)
    end)
  end
end
