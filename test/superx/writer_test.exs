defmodule SuperX.Content.WriterTest do
  @moduledoc """
  The premise of the product is that a draft borrows a proven post's
  *shape*, not its words. In practice the model substitutes nouns into the
  reference's skeleton and leaves its distinctive closing line intact,
  which would publish someone else's sentence under the user's name.
  """

  use ExUnit.Case, async: true

  alias SuperX.AI.Prompts
  alias SuperX.Content.Writer

  describe "creator idea prompts" do
    test "keeps external ideas separate from the author's voice evidence" do
      prompt =
        Prompts.write_from_topic(
          "durable software",
          ["I delete code before I add abstractions."],
          [%{handle: "builder", posts: ["Ownership is a product decision."]}]
        )

      assert prompt =~ "<author_voice_examples>"
      assert prompt =~ "I delete code before I add abstractions."
      assert prompt =~ "<creator_idea_material>"
      assert prompt =~ "@builder"
      assert prompt =~ "they say nothing about\nthis author's voice"
      assert prompt =~ "Never imitate these creators' voice"

      {voice_at, _} = :binary.match(prompt, "<author_voice_examples>")
      {ideas_at, _} = :binary.match(prompt, "<creator_idea_material>")
      assert voice_at < ideas_at
    end
  end

  describe "strip_thread_markers/1" do
    test "removes numbering the model wrote for itself" do
      # Observed in production: the whole thread in one segment, with the
      # marker publishing as literal text.
      assert Writer.strip_thread_markers("finally fixed that drawer - a thread: 1/4") ==
               "finally fixed that drawer"

      assert Writer.strip_thread_markers("1/ the part nobody mentions") ==
               "the part nobody mentions"

      assert Writer.strip_thread_markers("the part nobody mentions (2/5)") ==
               "the part nobody mentions"

      assert Writer.strip_thread_markers("what I'd do differently 🧵") ==
               "what I'd do differently"
    end

    test "leaves a fraction that is part of the sentence" do
      assert Writer.strip_thread_markers("3/4 of users never open it twice") ==
               "3/4 of users never open it twice"

      assert Writer.strip_thread_markers("we shipped it in half the time") ==
               "we shipped it in half the time"
    end
  end

  describe "derivative?/2" do
    test "catches the substitution failure seen in real output" do
      # swyx's post, 8.4K likes, and what the writer produced from it.
      source =
        "The best engineers I know are aggressively boring in their tool " <>
          "choices and aggressively creative in their problem framing. " <>
          "Most people get this exactly backwards."

      draft =
        "the best engineers i know are aggressively patient in their " <>
          "profiling and aggressively ruthless in what they cut. most " <>
          "people get this exactly backwards."

      assert Writer.derivative?(draft, source)
    end

    test "catches a lifted closing line on its own" do
      source = "Strategy is a set of choices. If it doesn't rule anything out, it isn't strategy."
      draft = "Roadmaps are a set of guesses. If it doesn't rule anything out, it isn't strategy."

      assert Writer.derivative?(draft, source)
    end

    test "passes a post that shares only shape" do
      source =
        "Every abstraction you add is a bet that the thing underneath " <>
          "won't change. Most of those bets lose, and you pay the interest forever."

      draft =
        "Every paragraph you write is a loan against the reader's attention. " <>
          "Most of them default, and you're the one who owes."

      refute Writer.derivative?(draft, source)
    end

    test "is not tripped by ordinary English overlap" do
      source = "One of the things that surprised me was how little the language mattered."
      draft = "One of the things that took longest was admitting the schema was wrong."

      # Five words of shared boilerplate is common; the guard should only
      # fire on longer runs than idiom accounts for.
      refute Writer.derivative?(draft, source)
    end

    test "catches a distinctive opening with one noun swapped" do
      # Observed in production: @kirkxxs at 14.6K likes, and what the
      # writer returned. No six-word run is shared, so the n-gram guard
      # alone let it through, but the opening is recognisably his.
      source =
        "the crux of twitter is that your personal thoughts can go viral " <>
          "and suddenly you have to deal w/ hundreds of people projecting"

      draft =
        "the crux of life is that you spend decades trying to become " <>
          "someone and suddenly you realise nobody was keeping score"

      assert Writer.derivative?(draft, source)
    end

    test "an opening of pure idiom is not a lift, however much of it matches" do
      # All five opening words coincide, but every one of them is
      # boilerplate — this is two people writing English, not one copying
      # the other.
      source = "One of the things that surprised me was how little the language mattered."
      draft = "One of the things that took longest was admitting the schema was wrong."

      refute Writer.derivative?(draft, source)
    end

    test "ignores case and punctuation, which substitution changes freely" do
      assert Writer.derivative?(
               "most people get this exactly backwards",
               "Most people get this, exactly backwards!"
             )
    end
  end
end
