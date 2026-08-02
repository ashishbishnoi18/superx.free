defmodule SuperXWeb.InspirationLiveTest do
  use SuperXWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.Accounts
  alias SuperX.Content.Corpus

  test "reveals only meaningful multiples and sorts by them", %{conn: conn} do
    %{user: user} = user_fixture()
    {:ok, token} = Accounts.create_session(user)

    Corpus.upsert_many([
      corpus_attrs("large-typical-1", 1_000, 100_000),
      corpus_attrs("large-typical-2", 1_000, 100_000),
      corpus_attrs("large-typical-3", 1_000, 100_000),
      corpus_attrs("large-best", 1_500, 100_000),
      corpus_attrs("small-typical-1", 100, 10_000),
      corpus_attrs("small-typical-2", 100, 10_000),
      corpus_attrs("small-typical-3", 100, 10_000),
      corpus_attrs("small-outlier", 300, 10_000)
    ])

    large_best = post("large-best")
    small_outlier = post("small-outlier")
    typical = post("small-typical-1")

    conn = init_test_session(conn, %{user_token: token})
    {:ok, view, _html} = live(conn, ~p"/inspiration")

    assert has_element?(view, "#outlier-toggle")
    refute has_element?(view, "#outlier-#{small_outlier.id}")

    view |> element("#outlier-toggle") |> render_click()

    assert has_element?(view, "#outlier-#{small_outlier.id}", "3.0× typical")
    refute has_element?(view, "#outlier-#{typical.id}")

    assert has_element?(
             view,
             "#inspiration-results > #inspiration-post-#{large_best.id}:first-child"
           )

    view |> element("#sort-outlier") |> render_click()

    assert has_element?(
             view,
             "#inspiration-results > #inspiration-post-#{small_outlier.id}:first-child"
           )
  end

  test "media and advanced filters combine and explain an empty result", %{conn: conn} do
    %{user: user} = user_fixture()
    {:ok, token} = Accounts.create_session(user)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    target =
      corpus_attrs("target", 500, 10_000)
      |> Map.merge(%{
        text: String.duplicate("A useful argument needs enough room to develop. ", 4),
        reposts: 30,
        replies: 20,
        bookmarks: 20,
        impressions: 2_000,
        media: [%{"type" => "photo", "url" => "https://images.example/target.jpg"}],
        posted_at: now
      })

    Corpus.upsert_many([
      target,
      Map.merge(target, %{x_post_id: "text-only", media: []}),
      Map.merge(target, %{x_post_id: "few-replies", replies: 2})
    ])

    target_post = post("target")
    text_only = post("text-only")
    few_replies = post("few-replies")
    conn = init_test_session(conn, %{user_token: token})
    {:ok, view, _html} = live(conn, ~p"/inspiration")

    assert has_element?(view, "#inspiration-post-#{text_only.id}")

    view |> element("#tab-media") |> render_click()

    refute has_element?(view, "#inspiration-post-#{text_only.id}")
    assert has_element?(view, "#inspiration-post-#{target_post.id}")
    assert has_element?(view, "#inspiration-post-#{few_replies.id}")

    filters = %{
      "min_reposts" => "30",
      "min_replies" => "20",
      "min_bookmarks" => "10",
      "min_views" => "2000",
      "min_length" => "120",
      "date_from" => Date.utc_today() |> Date.add(-1) |> Date.to_iso8601(),
      "date_to" => Date.utc_today() |> Date.to_iso8601()
    }

    view
    |> form("#advanced-filter-form", filters: filters)
    |> render_change()

    assert has_element?(view, "#inspiration-post-#{target_post.id}")
    refute has_element?(view, "#inspiration-post-#{few_replies.id}")

    assert has_element?(
             view,
             "#inspiration-post-#{target_post.id} img[src='https://images.example/target.jpg']"
           )

    view
    |> form("#advanced-filter-form", filters: Map.put(filters, "min_bookmarks", "21"))
    |> render_change()

    assert has_element?(view, "#inspiration-filter-empty", "Media")
    assert has_element?(view, "#inspiration-filter-empty", "21+ bookmarks")
  end

  test "shows when an outlier baseline has too few comparable posts", %{conn: conn} do
    %{user: user} = user_fixture()
    {:ok, token} = Accounts.create_session(user)

    post =
      corpus_post_fixture(%{
        x_post_id: "thin-band",
        author_followers: 500,
        likes: 90_000
      })

    conn = init_test_session(conn, %{user_token: token})
    {:ok, view, _html} = live(conn, ~p"/inspiration")

    view |> element("#outlier-toggle") |> render_click()

    assert has_element?(view, "#outlier-unavailable-#{post.id}", "Not enough comparable posts")
    refute has_element?(view, "#outlier-#{post.id}", "1.0× typical")
  end

  defp corpus_attrs(id, likes, followers) do
    %{
      x_post_id: id,
      author_handle: "author-#{id}",
      author_followers: followers,
      text:
        "The thing nobody tells you about shipping is that the last ten percent " <>
          "takes as long as the first ninety, and it is the only part anyone sees.",
      likes: likes,
      reposts: 0,
      replies: 0,
      quotes: 0,
      bookmarks: 0,
      posted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp post(x_post_id), do: SuperX.Repo.get_by!(SuperX.Content.CorpusPost, x_post_id: x_post_id)
end
