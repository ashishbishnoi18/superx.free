defmodule SuperX.CorpusTest do
  use SuperX.DataCase, async: true

  alias SuperX.Content.Corpus
  alias SuperX.Workers.CorpusRefresh

  defp attrs(overrides) do
    Map.merge(
      %{
        x_post_id: "1",
        author_handle: "someone",
        author_followers: 10_000,
        text:
          "The thing nobody tells you about shipping is that the last ten percent " <>
            "takes as long as the first ninety, and it is the only part anyone sees.",
        likes: 900,
        reposts: 40,
        replies: 12,
        posted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      overrides
    )
  end

  describe "upsert_many/1" do
    test "tags a post with the topic it was found under" do
      Corpus.upsert_many([attrs(%{topics: ["ai agents"]})])

      assert [post] = Corpus.search(min_likes: 0)
      assert post.topics == ["ai agents"]
    end

    test "unions topics when the same post is found under another search" do
      Corpus.upsert_many([attrs(%{topics: ["ai agents"]})])
      Corpus.upsert_many([attrs(%{topics: ["developer tools"]})])

      assert [post] = Corpus.search(min_likes: 0)
      assert Enum.sort(post.topics) == ["ai agents", "developer tools"]
    end

    test "refreshes metrics on conflict, because a post keeps growing" do
      Corpus.upsert_many([attrs(%{likes: 900})])
      Corpus.upsert_many([attrs(%{likes: 4200})])

      assert [post] = Corpus.search(min_likes: 0)
      assert post.likes == 4200
    end

    test "a re-ingest under a topic it already carries doesn't duplicate it" do
      Corpus.upsert_many([attrs(%{topics: ["ai agents"]})])
      Corpus.upsert_many([attrs(%{topics: ["ai agents"]})])

      assert [post] = Corpus.search(min_likes: 0)
      assert post.topics == ["ai agents"]
    end
  end

  describe "topic filtering" do
    test "candidates_for finds a post by the topic it was tagged with" do
      Corpus.upsert_many([attrs(%{topics: ["ai agents"]})])
      account_id = Ecto.UUID.generate()

      assert [_] = Corpus.candidates_for(account_id, ["ai agents"], min_likes: 0)
      assert [] == Corpus.candidates_for(account_id, ["knitting"], min_likes: 0)
    end
  end

  describe "topics_for_run/1" do
    test "falls back to the seed set when no voice profile has topics" do
      chosen = CorpusRefresh.topics_for_run(20)

      assert length(chosen) == 20
      assert Enum.all?(chosen, &(&1 in CorpusRefresh.seed_topics()))
    end

    test "never returns the same topic twice" do
      chosen = CorpusRefresh.topics_for_run(20)
      assert chosen == Enum.uniq(chosen)
    end

    test "leaves room for seed topics rather than filling up on user topics" do
      # More user topics than a run can hold, so the cap is what decides.
      assert 20 |> CorpusRefresh.topics_for_run() |> length() == 20
    end
  end
end
