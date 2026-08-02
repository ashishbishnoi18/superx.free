defmodule SuperX.CorpusTest do
  # The sample-floor tests temporarily change application configuration,
  # which is global even though the database sandbox is not.
  use SuperX.DataCase, async: false

  alias SuperX.Content.{Corpus, Exclusions}
  alias SuperX.Workers.{CorpusIngest, CorpusRefresh, EmbedCorpus}

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

  describe "advanced filtering" do
    test "combines media, metric, length, and date constraints in SQL" do
      matching =
        attrs(%{
          x_post_id: "matching",
          reposts: 30,
          replies: 20,
          bookmarks: 10,
          impressions: 2_000,
          media: [%{"type" => "photo", "url" => "https://images.example/matching.jpg"}],
          posted_at: ~U[2026-07-15 12:00:00Z]
        })

      Corpus.upsert_many([
        matching,
        Map.merge(matching, %{x_post_id: "without-media", media: []}),
        Map.merge(matching, %{x_post_id: "few-reposts", reposts: 29}),
        Map.merge(matching, %{x_post_id: "few-replies", replies: 19}),
        Map.merge(matching, %{x_post_id: "few-bookmarks", bookmarks: 9}),
        Map.merge(matching, %{x_post_id: "few-views", impressions: 1_999}),
        Map.merge(matching, %{x_post_id: "too-short", text: String.duplicate("x", 119)}),
        Map.merge(matching, %{x_post_id: "too-early", posted_at: ~U[2026-07-09 23:59:59Z]}),
        Map.merge(matching, %{x_post_id: "too-late", posted_at: ~U[2026-07-21 00:00:00Z]})
      ])

      results =
        Corpus.search(
          min_likes: 0,
          min_reposts: 30,
          min_replies: 20,
          min_bookmarks: 10,
          min_views: 2_000,
          min_length: 120,
          since: ~U[2026-07-10 00:00:00Z],
          until: ~U[2026-07-20 23:59:59Z],
          has_media: true
        )

      assert Enum.map(results, & &1.x_post_id) == ["matching"]
    end
  end

  describe "outlier detection" do
    test "benchmarks engagement against the median for a comparable account size" do
      Corpus.upsert_many([
        outlier_attrs("typical-1", 100),
        outlier_attrs("typical-2", 100),
        outlier_attrs("typical-3", 100),
        outlier_attrs("outlier", 300)
      ])

      scores =
        Corpus.search(min_likes: 0, sort: :outlier)
        |> Map.new(&{&1.x_post_id, &1.outlier_score})

      assert_in_delta scores["typical-1"], 1.0, 0.001
      assert_in_delta scores["outlier"], 3.0, 0.001
    end

    test "refreshes the whole affected band when a post's metrics change" do
      Corpus.upsert_many([
        outlier_attrs("typical-1", 100),
        outlier_attrs("typical-2", 100),
        outlier_attrs("typical-3", 100),
        outlier_attrs("outlier", 300)
      ])

      Corpus.upsert_many([outlier_attrs("typical-1", 300)])

      outlier =
        Corpus.search(min_likes: 0, sort: :outlier)
        |> Enum.find(&(&1.x_post_id == "outlier"))

      assert_in_delta outlier.outlier_score, 1.5, 0.001
    end

    test "refreshes the old band when an author's reach crosses a boundary" do
      Corpus.upsert_many([
        outlier_attrs("low", 100),
        outlier_attrs("middle", 200),
        outlier_attrs("moving", 300)
      ])

      Corpus.upsert_many([outlier_attrs("moving", 300, 100_000)])

      low =
        Corpus.search(min_likes: 0, sort: :outlier)
        |> Enum.find(&(&1.x_post_id == "low"))

      assert_in_delta low.outlier_score, 2 / 3, 0.001
    end

    test "sorts by performance relative to reach rather than raw engagement" do
      Corpus.upsert_many([
        outlier_attrs("large-typical-1", 1_000, 100_000),
        outlier_attrs("large-typical-2", 1_000, 100_000),
        outlier_attrs("large-typical-3", 1_000, 100_000),
        outlier_attrs("large-best", 1_500, 100_000),
        outlier_attrs("small-typical-1", 100, 10_000),
        outlier_attrs("small-typical-2", 100, 10_000),
        outlier_attrs("small-typical-3", 100, 10_000),
        outlier_attrs("small-outlier", 300, 10_000)
      ])

      assert [%{x_post_id: "large-best"} | _] =
               Corpus.search(min_likes: 0, sort: :engagement)

      assert [%{x_post_id: "small-outlier"} | _] =
               Corpus.search(min_likes: 0, sort: :outlier)
    end

    test "optionally keeps only proven outliers for writer candidates" do
      Corpus.upsert_many([
        outlier_attrs("typical-1", 100),
        outlier_attrs("typical-2", 100),
        outlier_attrs("typical-3", 100),
        outlier_attrs("outlier", 300)
      ])

      candidates =
        Corpus.candidates_for(Ecto.UUID.generate(), nil,
          min_likes: 0,
          min_outlier: 2.5
        )

      assert Enum.map(candidates, & &1.x_post_id) == ["outlier"]
    end
  end

  describe "usable_as_template" do
    test "keeps a post whose shape transfers" do
      Corpus.upsert_many([attrs(%{})])
      assert [_] = Corpus.candidates_for(Ecto.UUID.generate(), nil, min_likes: 0)
    end

    test "rejects a news alert, whose shape is the event rather than the writing" do
      Corpus.upsert_many([
        attrs(%{
          text:
            "BREAKING: a major announcement has just been made and everyone is " <>
              "reacting to it across every timeline on the platform right now."
        })
      ])

      assert [] == Corpus.candidates_for(Ecto.UUID.generate(), nil, min_likes: 0)
    end

    test "rejects a post promising a list it never delivers" do
      Corpus.upsert_many([
        attrs(%{
          text:
            "the best conversations happen in doorways. 3 types of goodbyes " <>
              "that tell you everything about how someone actually feels."
        })
      ])

      assert [] == Corpus.candidates_for(Ecto.UUID.generate(), nil, min_likes: 0)
    end

    test "does not reject a post that merely contains the word breaking" do
      Corpus.upsert_many([
        attrs(%{
          text:
            "The habit that changed my writing was breaking every paragraph into " <>
              "its own line until the argument had nowhere left to hide from me."
        })
      ])

      assert [_] = Corpus.candidates_for(Ecto.UUID.generate(), nil, min_likes: 0)
    end
  end

  describe "the outlier sample floor" do
    setup do
      # Production requires 30 posts behind a median. The suite runs with
      # a floor of 1 so the maths can be tested on small fixtures, so the
      # floor itself has to be reinstated here.
      previous = Application.get_env(:superx, :min_outlier_baseline_sample)
      Application.put_env(:superx, :min_outlier_baseline_sample, 30)
      on_exit(fn -> Application.put_env(:superx, :min_outlier_baseline_sample, previous) end)
    end

    test "suppresses the multiple when the band has too few posts to judge" do
      # This post is the only one in its band, so its own engagement *is*
      # the median. A median of one is not evidence, and reporting it as a
      # huge outlier would be an artefact of the sample.
      Corpus.upsert_many([attrs(%{x_post_id: "solo", author_followers: 500, likes: 90_000})])

      assert [post] = Corpus.search(min_likes: 0)
      assert is_nil(post.outlier_score)
    end

    test "min_outlier never filters against a band it cannot judge" do
      Corpus.upsert_many([attrs(%{x_post_id: "solo", author_followers: 500, likes: 90_000})])

      assert [] ==
               Corpus.candidates_for(Ecto.UUID.generate(), nil, min_likes: 0, min_outlier: 2.0)
    end
  end

  describe "exclusions" do
    test "a political post is never offered as a template" do
      Corpus.upsert_many([
        attrs(%{
          text:
            "The thing nobody tells you about the senate race is that the last " <>
              "ten percent of the campaign takes as long as the first ninety."
        })
      ])

      assert [] == Corpus.candidates_for(Ecto.UUID.generate(), nil, min_likes: 0)
    end

    test "but Inspiration still shows it unless the filter is on" do
      Corpus.upsert_many([
        attrs(%{
          text:
            "The thing nobody tells you about the senate race is that the last " <>
              "ten percent of the campaign takes as long as the first ninety."
        })
      ])

      assert [_] = Corpus.search(min_likes: 0)
      assert [] == Corpus.search(min_likes: 0, exclude: ["politics"])
      assert [_] = Corpus.search(min_likes: 0, exclude: ["crypto"])
    end

    test "pattern_for/1 returns nil when nothing is excluded" do
      assert is_nil(Exclusions.pattern_for([]))
      assert is_nil(Exclusions.pattern_for(nil))
    end
  end

  describe "specific?/1" do
    test "rejects topics that name a posture rather than a subject" do
      refute CorpusRefresh.specific?("life")
      refute CorpusRefresh.specific?("personal thoughts")
      refute CorpusRefresh.specific?("everyday observations")
      refute CorpusRefresh.specific?("random stuff")
    end

    test "keeps topics that name an actual subject" do
      assert CorpusRefresh.specific?("AI agents")
      assert CorpusRefresh.specific?("personal branding")
      assert CorpusRefresh.specific?("my climbing life")
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

  describe "corpus refresh execution" do
    test "uses the scraper when it is the configured read source" do
      previous_twitter = Application.get_env(:superx, SuperX.TwitterAPI, [])
      previous_refresh = Application.get_env(:superx, CorpusRefresh, [])
      scraper_state = :sys.get_state(SuperX.Scraper)
      test_pid = self()

      Application.put_env(
        :superx,
        SuperX.TwitterAPI,
        Keyword.put(previous_twitter, :api_key, nil)
      )

      Application.put_env(
        :superx,
        CorpusRefresh,
        enqueue_topics: fn topics, opts -> send(test_pid, {:enqueued, topics, opts}) end
      )

      :sys.replace_state(SuperX.Scraper, &%{&1 | configured: true})

      on_exit(fn ->
        Application.put_env(:superx, SuperX.TwitterAPI, previous_twitter)
        Application.put_env(:superx, CorpusRefresh, previous_refresh)
        :sys.replace_state(SuperX.Scraper, fn _state -> scraper_state end)
      end)

      assert :ok =
               CorpusRefresh.perform(%Oban.Job{
                 args: %{"limit_topics" => 2, "spacing_seconds" => 0}
               })

      assert_receive {:enqueued, topics, opts}
      assert length(topics) == 2
      assert opts[:spacing_seconds] == 0
    end

    test "queues corpus topics immediately by default" do
      assert [first, second] = CorpusIngest.topic_jobs(["audit topic one", "audit topic two"])

      first_at = Ecto.Changeset.get_field(first, :scheduled_at)
      second_at = Ecto.Changeset.get_field(second, :scheduled_at)
      assert DateTime.diff(second_at, first_at, :second) <= 1
    end
  end

  describe "embedding backlog" do
    test "returns provider failures so Oban retries the batch" do
      configure_embedder(fn _inputs, _opts -> {:error, :provider_down} end)
      Corpus.upsert_many([attrs(%{x_post_id: "embed-failure"})])

      assert {:error, :provider_down} = EmbedCorpus.perform(%Oban.Job{})
    end

    test "snoozes the same job after a full batch so uniqueness cannot discard the continuation" do
      vector = List.duplicate(0.0, 1024)

      configure_embedder(fn inputs, _opts ->
        {:ok, List.duplicate(vector, length(inputs))}
      end)

      posts = Enum.map(1..64, &attrs(%{x_post_id: "embed-#{&1}"}))
      Corpus.upsert_many(posts)

      assert {:snooze, 5} = EmbedCorpus.perform(%Oban.Job{})
      assert Corpus.list_unembedded() == []
    end
  end

  defp outlier_attrs(id, likes, followers \\ 10_000) do
    attrs(%{
      x_post_id: id,
      author_followers: followers,
      likes: likes,
      reposts: 0,
      replies: 0,
      quotes: 0,
      bookmarks: 0
    })
  end

  defp configure_embedder(fun) do
    previous = Application.get_env(:superx, EmbedCorpus, [])
    Application.put_env(:superx, EmbedCorpus, embed: fun)
    on_exit(fn -> Application.put_env(:superx, EmbedCorpus, previous) end)
  end
end
