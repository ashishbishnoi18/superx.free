defmodule SuperX.Content.WriterTest do
  @moduledoc """
  The premise of the product is that a draft borrows a proven post's
  *shape*, not its words. In practice the model substitutes nouns into the
  reference's skeleton and leaves its distinctive closing line intact,
  which would publish someone else's sentence under the user's name.
  """

  use ExUnit.Case, async: true

  alias SuperX.Content.Writer

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

    test "ignores case and punctuation, which substitution changes freely" do
      assert Writer.derivative?(
               "most people get this exactly backwards",
               "Most people get this, exactly backwards!"
             )
    end
  end
end
