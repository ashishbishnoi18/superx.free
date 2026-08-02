defmodule SuperX.ArticlesTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.Articles
  alias SuperX.Articles.Article

  describe "composition" do
    test "derives word count instead of trusting submitted data" do
      %{user: user, account: account} = user_fixture()

      assert {:ok, article} =
               Articles.create_article(user, account, %{
                 title: "A measured argument",
                 body: "One\n\ntwo   three",
                 word_count: 99_999
               })

      assert article.user_id == user.id
      assert article.x_account_id == account.id
      assert article.word_count == 3
      assert article.status == "draft"
    end

    test "ready articles require a title and body" do
      %{user: user, account: account} = user_fixture()

      assert {:error, changeset} =
               Articles.create_article(user, account, %{status: "ready", body: ""})

      assert "can't be blank" in errors_on(changeset).title
      assert "can't be blank" in errors_on(changeset).body
    end

    test "reads never cross user or account ownership" do
      %{user: owner, account: account} = user_fixture()
      %{user: other_user, account: other_account} = user_fixture()

      {:ok, article} = Articles.create_article(owner, account, %{title: "Private draft"})

      assert Articles.get_article(owner, account, article.id) == article
      assert Articles.get_article(other_user, other_account, article.id) == nil
      assert Articles.create_article(owner, other_account, %{}) == {:error, :account_mismatch}
    end

    test "lists and counts lifecycle states within one account" do
      %{user: user, account: account} = user_fixture()

      {:ok, _draft} = Articles.create_article(user, account, %{title: "Draft"})

      {:ok, ready} =
        Articles.create_article(user, account, %{
          title: "Ready",
          body: "Finished prose.",
          status: "ready"
        })

      assert [listed] = Articles.list_articles(account, "ready")
      assert listed.id == ready.id
      assert Articles.counts(account) == %{"draft" => 1, "published" => 0, "ready" => 1}
    end
  end

  describe "publication" do
    test "only records a complete confirmed destination" do
      %{user: user, account: account} = user_fixture()

      {:ok, article} =
        Articles.create_article(user, account, %{
          title: "Complete",
          body: "A complete article.",
          status: "ready"
        })

      assert {:error, changeset} = Articles.record_published(article, %{})
      assert "can't be blank" in errors_on(changeset).permalink
      assert "can't be blank" in errors_on(changeset).x_post_id

      assert {:ok, published} =
               Articles.record_published(article, %{
                 x_article_id: "x-article-1",
                 x_post_id: "x-post-1",
                 permalink: "https://x.com/i/status/x-post-1"
               })

      assert %Article{status: "published"} = published
      assert published.published_at
      assert published.x_article_id == "x-article-1"
      assert published.x_post_id == "x-post-1"
    end

    test "creates and publishes the X draft in order, then refuses a second publish" do
      %{user: user, account: account} = user_fixture()

      {:ok, article} =
        Articles.create_article(user, account, %{
          title: "A careful argument",
          body: "First paragraph.\n\nSecond paragraph.",
          status: "ready"
        })

      counter = start_supervised!({Agent, fn -> 0 end})

      Req.Test.stub(SuperX.X, fn conn ->
        request = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        case request do
          1 ->
            assert conn.method == "POST"
            assert conn.request_path == "/2/articles/draft"

            assert Jason.decode!(body) == %{
                     "title" => "A careful argument",
                     "content_state" => %{
                       "blocks" => [
                         %{"text" => "First paragraph.", "type" => "unstyled"},
                         %{"text" => "Second paragraph.", "type" => "unstyled"}
                       ],
                       "entities" => []
                     }
                   }

            json(conn, 201, %{"data" => %{"id" => "x-article-1", "title" => article.title}})

          2 ->
            assert conn.method == "POST"
            assert conn.request_path == "/2/articles/x-article-1/publish"
            assert Jason.decode!(body) == %{}
            json(conn, 200, %{"data" => %{"post_id" => "x-post-1"}})
        end
      end)

      assert {:ok, published} = Articles.publish(article, "access-token")
      assert published.status == "published"
      assert published.x_article_id == "x-article-1"
      assert published.x_post_id == "x-post-1"
      assert published.permalink == "https://x.com/i/status/x-post-1"
      assert Agent.get(counter, & &1) == 2

      assert {:error, :already_published} = Articles.publish(article, "access-token")
      assert Agent.get(counter, & &1) == 2
    end

    test "keeps a rejected article unpublished and retains X's detail" do
      %{user: user, account: account} = user_fixture()

      {:ok, article} =
        Articles.create_article(user, account, %{
          title: "Ready for review",
          body: "Prose that passed local review.",
          status: "ready"
        })

      counter = start_supervised!({Agent, fn -> 0 end})

      Req.Test.stub(SuperX.X, fn conn ->
        request = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

        case request do
          1 ->
            json(conn, 201, %{"data" => %{"id" => "x-article-rejected"}})

          2 ->
            json(conn, 400, %{
              "errors" => [%{"detail" => "Article text violates an X rule."}]
            })
        end
      end)

      assert {:error, {:http_error, 400, _body}} =
               Articles.publish(article, "access-token")

      rejected = Articles.get_article(user, account, article.id)
      assert rejected.status == "ready"
      assert rejected.published_at == nil
      assert rejected.x_post_id == nil
      assert rejected.permalink == nil
      assert rejected.x_article_id == "x-article-rejected"
      assert rejected.publish_error == "X returned 400: Article text violates an X rule."
    end

    test "a stale editor cannot return a claimed article to ready" do
      %{user: user, account: account} = user_fixture()

      {:ok, article} =
        Articles.create_article(user, account, %{
          title: "One publisher",
          body: "The review state must survive stale browser tabs.",
          status: "ready"
        })

      assert {:ok, claimed} = Articles.claim_for_publishing(article.id)
      assert claimed.status == "publishing"

      assert {:error, :read_only} =
               Articles.update_article(article, %{status: "ready", title: "Stale edit"})

      assert Articles.get_article(user, account, article.id).status == "publishing"
    end
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
