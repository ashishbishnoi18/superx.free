defmodule SuperX.EngageTest do
  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.Engage
  alias SuperX.Engage.{Engagement, Feed}

  setup do
    user_fixture()
  end

  defp attrs(account, overrides) do
    Map.merge(
      %{
        x_account_id: account.id,
        kind: "mention",
        x_post_id: "post-#{System.unique_integer([:positive])}",
        author_handle: "someone",
        text: "a question worth answering",
        posted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        likes: 1
      },
      overrides
    )
  end

  describe "upsert_many/1" do
    test "re-polling updates metrics instead of duplicating", %{account: account} do
      base = attrs(account, %{x_post_id: "p1", likes: 5})

      assert {1, _} = Engage.upsert_many([base])
      assert {1, _} = Engage.upsert_many([%{base | likes: 90}])

      assert [engagement] = Engage.list_engagements(account)
      assert engagement.likes == 90
    end

    test "re-polling does not reopen something already dealt with", %{account: account} do
      base = attrs(account, %{x_post_id: "p2"})
      Engage.upsert_many([base])

      [engagement] = Engage.list_engagements(account)
      {:ok, _} = Engage.ignore(engagement)

      # The poller sees the same post again on the next run.
      Engage.upsert_many([%{base | likes: 40}])

      assert Engage.list_engagements(account, status: "open") == []
      assert [%{status: "ignored"}] = Engage.list_engagements(account, status: "ignored")
    end

    test "collapses duplicates within a single batch", %{account: account} do
      base = attrs(account, %{x_post_id: "p3"})

      assert {1, _} = Engage.upsert_many([base, base])
    end

    test "drops invalid rows without failing the batch", %{account: account} do
      good = attrs(account, %{x_post_id: "good"})
      bad = attrs(account, %{x_post_id: "bad", text: nil})

      assert {1, _} = Engage.upsert_many([good, bad])
    end

    test "assigns a heuristic priority when none is supplied", %{account: account} do
      Engage.upsert_many([attrs(account, %{author_followers: 50_000, likes: 100})])

      assert [%{priority: priority}] = Engage.list_engagements(account)
      assert is_integer(priority) and priority > 0
    end
  end

  describe "inbox ordering" do
    test "leads with priority, not recency", %{account: account} do
      old_important =
        attrs(account, %{
          x_post_id: "important",
          priority: 95,
          posted_at: DateTime.utc_now() |> DateTime.add(-86_400) |> DateTime.truncate(:second)
        })

      new_trivial = attrs(account, %{x_post_id: "trivial", priority: 5})

      Engage.upsert_many([old_important, new_trivial])

      assert [%{x_post_id: "important"}, %{x_post_id: "trivial"}] =
               Engage.list_engagements(account)
    end
  end

  describe "counts" do
    test "counts open items per kind", %{account: account} do
      Engage.upsert_many([
        attrs(account, %{x_post_id: "m1", kind: "mention"}),
        attrs(account, %{x_post_id: "f1", kind: "feed"}),
        attrs(account, %{x_post_id: "f2", kind: "feed"})
      ])

      counts = Engage.counts(account)
      assert counts["mention"] == 1
      assert counts["feed"] == 2
      assert counts["all"] == 3
    end

    test "ignored items leave the counts", %{account: account} do
      Engage.upsert_many([attrs(account, %{x_post_id: "m1"})])
      [e] = Engage.list_engagements(account)
      {:ok, _} = Engage.ignore(e)

      assert Engage.counts(account)["all"] == 0
    end
  end

  describe "heuristic priority" do
    test "rewards effort and traction, not follower count alone" do
      whale_one_word = %Engagement{
        author_followers: 1_000_000,
        text: "this",
        likes: 0,
        reposts: 0
      }

      small_substantive = %Engagement{
        author_followers: 400,
        text: String.duplicate("a considered reply. ", 12),
        likes: 30,
        reposts: 6
      }

      # Not a claim that the small account wins outright — only that effort
      # and traction move the number enough to matter.
      assert Engagement.heuristic_priority(small_substantive) >
               Engagement.heuristic_priority(%{
                 small_substantive
                 | text: "ok",
                   likes: 0,
                   reposts: 0
               })

      assert Engagement.heuristic_priority(whale_one_word) < 100
    end
  end

  describe "feeds" do
    test "offers the complete ready-made set with search queries distinct from its labels" do
      suggestions = Feed.suggestions()

      assert Enum.map(suggestions, & &1.name) == [
               "Artificial Intelligence",
               "Build in Public",
               "Startups",
               "Technology",
               "Design",
               "Software Development",
               "Marketing",
               "Business & Finance",
               "Personal Finance",
               "Cryptocurrency",
               "Science",
               "Health & Fitness",
               "Career",
               "Memes"
             ]

      assert Enum.all?(suggestions, &(&1.query != &1.name))
      assert suggestions |> Enum.map(& &1.query) |> Enum.uniq() |> length() == 14
    end

    test "the same query cannot be added twice", %{account: account} do
      assert {:ok, _} = Engage.create_feed(account, %{query: "build in public"})
      assert {:error, changeset} = Engage.create_feed(account, %{query: "build in public"})
      assert "is already a feed" in errors_on(changeset).query
    end

    test "names itself from the query when unnamed", %{account: account} do
      assert {:ok, feed} = Engage.create_feed(account, %{query: "indie hackers"})
      assert feed.name == "indie hackers"
    end

    test "defaults to relevance and persists newest-first per feed", %{account: account} do
      assert {:ok, feed} = Engage.create_feed(account, %{query: "software founders"})
      assert feed.ranking == "relevance"
      assert Feed.search_type(feed) == "Top"

      assert {:ok, feed} = Engage.set_feed_ranking(account, feed.id, "newest")
      assert feed.ranking == "newest"
      assert Feed.search_type(feed) == "Latest"
    end

    test "rejects unknown ranking modes", %{account: account} do
      assert {:ok, feed} = Engage.create_feed(account, %{query: "product design"})
      assert {:error, changeset} = Engage.set_feed_ranking(account, feed.id, "popular")
      assert "is invalid" in errors_on(changeset).ranking
    end

    test "does not change a feed belonging to another account", %{account: account} do
      %{account: other_account} = user_fixture()
      assert {:ok, feed} = Engage.create_feed(other_account, %{query: "career advice"})

      assert {:error, :not_found} = Engage.set_feed_ranking(account, feed.id, "newest")
    end

    test "quality floor requires both established reach and visible engagement" do
      good = %{
        "likeCount" => 3,
        "retweetCount" => 1,
        "replyCount" => 1,
        "author" => %{"followers" => 100}
      }

      assert Feed.passes_quality_floor?(good)
      refute Feed.passes_quality_floor?(put_in(good, ["author", "followers"], 99))
      refute Feed.passes_quality_floor?(%{good | "likeCount" => 2, "retweetCount" => 0})
    end

    test "feeds_due excludes recently synced ones", %{account: account} do
      {:ok, fresh} = Engage.create_feed(account, %{query: "fresh"})
      {:ok, _stale} = Engage.create_feed(account, %{query: "stale"})

      {:ok, _} = Engage.touch_feed(fresh)

      queries = Engage.feeds_due() |> Enum.map(& &1.query)
      assert "stale" in queries
      refute "fresh" in queries
    end
  end
end
