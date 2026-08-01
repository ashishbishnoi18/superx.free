defmodule SuperXWeb.ArticlesLiveTest do
  use SuperXWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Articles}

  setup %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, token} = Accounts.create_session(user)

    %{conn: init_test_session(conn, %{user_token: token}), user: user, account: account}
  end

  test "writes a draft from the editor and reflects its live word count", %{
    conn: conn,
    account: account
  } do
    {:ok, view, _html} = live(conn, ~p"/articles")

    assert has_element?(view, "#articles-tabs")
    assert has_element?(view, "#articles-empty")

    view |> element("#new-article") |> render_click()
    assert_patch(view, ~p"/articles/new")
    assert has_element?(view, "#article-editor-form")

    view
    |> form("#article-editor-form", %{
      "article" => %{"title" => "An article", "body" => "three careful words"}
    })
    |> render_change()

    assert has_element?(view, "#article-editor-form", "3 words")

    render_submit(view, "article_action", %{
      "intent" => "save_draft",
      "article" => %{"title" => "An article", "body" => "three careful words"}
    })

    assert [article] = Articles.list_articles(account, "draft")
    assert_patch(view, ~p"/articles/#{article.id}/edit")
    assert article.word_count == 3
  end
end
