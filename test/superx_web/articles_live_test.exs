defmodule SuperXWeb.ArticlesLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Articles, Repo}
  alias SuperX.Articles.Article
  alias SuperX.Workers.PublishArticle

  setup %{conn: conn} do
    previous = Application.get_env(:superx, SuperX.AI, [])

    Application.put_env(
      :superx,
      SuperX.AI,
      Keyword.merge(previous, api_key: "test-key", writer_model: "test-model")
    )

    on_exit(fn -> Application.put_env(:superx, SuperX.AI, previous) end)

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

  test "autosaves long-form work before the user navigates away", %{
    conn: conn,
    account: account
  } do
    {:ok, view, _html} = live(conn, ~p"/articles/new")

    view
    |> form("#article-editor-form", %{
      "article" => %{
        "title" => "Work that must survive",
        "body" => "A long-form draft should not depend on remembering to click save."
      }
    })
    |> render_change()

    assert [article] = Articles.list_articles(account, "draft")
    assert_patch(view, ~p"/articles/#{article.id}/edit")

    view |> element("#articles-editor-back") |> render_click()
    assert_patch(view, ~p"/articles?tab=draft")
    assert has_element?(view, "#article-#{article.id}", "Work that must survive")

    view |> element("#article-#{article.id} a", "Work that must survive") |> render_click()
    assert_patch(view, ~p"/articles/#{article.id}/edit")
    assert has_element?(view, "#article-title[value='Work that must survive']")
    assert has_element?(view, "#article-body", "A long-form draft should not depend")
  end

  test "persists AI-written prose as soon as the composition finishes", %{
    conn: conn,
    account: account
  } do
    test_pid = self()

    Req.Test.stub(SuperX.AI, fn conn ->
      send(test_pid, {:article_writer_waiting, self()})

      receive do
        :return_article ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "article_1",
                  "name" => "respond",
                  "input" => %{
                    "title" => "Generated work that survives",
                    "body" => "The provider response is saved before the user can navigate away."
                  }
                }
              ]
            })
          )
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/articles/new")

    render_submit(view, "article_action", %{
      "intent" => "ai_draft",
      "article" => %{"title" => "", "body" => ""},
      "ai" => %{"instruction" => "Explain why finished generations should be durable."}
    })

    assert_receive {:article_writer_waiting, writer_pid}
    writer_ref = Process.monitor(writer_pid)
    send(writer_pid, :return_article)
    assert_receive {:DOWN, ^writer_ref, :process, ^writer_pid, :normal}

    # The task sends the result before exiting. A synchronous state read
    # guarantees the LiveView has handled that message without a timing sleep.
    _ = :sys.get_state(view.pid)

    assert [article] = Articles.list_articles(account, "draft")
    assert article.title == "Generated work that survives"
    assert article.body =~ "saved before the user can navigate away"
    assert_patch(view, ~p"/articles/#{article.id}/edit")
  end

  test "publishes a ready article with a durable pending state and permalink", %{
    conn: conn,
    user: user,
    account: account
  } do
    {:ok, article} = ready_article(user, account, "Ready to publish")
    {:ok, view, _html} = live(conn, ~p"/articles?tab=ready")

    assert has_element?(view, "#publish-article-#{article.id}")
    view |> element("#publish-article-#{article.id}") |> render_click()

    assert has_element?(view, "#article-publishing-#{article.id}")
    assert Repo.get!(Article, article.id).status == "publishing"

    Req.Test.stub(SuperX.X, fn conn ->
      case conn.request_path do
        "/2/articles/draft" ->
          json(conn, 201, %{"data" => %{"id" => "x-article-live"}})

        "/2/articles/x-article-live/publish" ->
          json(conn, 200, %{"data" => %{"post_id" => "x-post-live"}})
      end
    end)

    assert :ok =
             PublishArticle.perform(%Oban.Job{
               args: %{"article_id" => article.id},
               attempt: 1
             })

    _ = :sys.get_state(view.pid)

    view |> element("#articles-tab-published") |> render_click()
    assert_patch(view, ~p"/articles?tab=published")

    assert has_element?(
             view,
             "#article-#{article.id} a[href='https://x.com/i/status/x-post-live']"
           )
  end

  test "shows X's reason when a ready article is refused", %{
    conn: conn,
    user: user,
    account: account
  } do
    {:ok, article} = ready_article(user, account, "Rejected by X")
    {:ok, view, _html} = live(conn, ~p"/articles?tab=ready")

    view |> element("#publish-article-#{article.id}") |> render_click()

    Req.Test.stub(SuperX.X, fn conn ->
      json(conn, 400, %{"detail" => "This Article cannot be published."})
    end)

    assert :ok =
             PublishArticle.perform(%Oban.Job{
               args: %{"article_id" => article.id},
               attempt: 1
             })

    _ = :sys.get_state(view.pid)

    assert has_element?(
             view,
             "#article-publish-error-#{article.id}",
             "X returned 400: This Article cannot be published."
           )

    assert Repo.get!(Article, article.id).status == "ready"
  end

  defp ready_article(user, account, title) do
    Articles.create_article(user, account, %{
      title: title,
      body: "Reviewed long-form prose.",
      status: "ready"
    })
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
