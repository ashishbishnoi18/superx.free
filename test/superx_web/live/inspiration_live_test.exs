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
