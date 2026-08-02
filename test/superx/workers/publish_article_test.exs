defmodule SuperX.Workers.PublishArticleTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.{Articles, Repo}
  alias SuperX.Articles.Article
  alias SuperX.Workers.PublishArticle

  test "keeps the claim and snoozes until X's rate-limit window", %{} do
    %{user: user, account: account} = user_fixture()

    {:ok, article} =
      Articles.create_article(user, account, %{
        title: "Wait for the window",
        body: "This must not turn into a duplicate while X is rate limiting.",
        status: "ready"
      })

    {:ok, claimed, _job} = PublishArticle.enqueue(article)
    assert claimed.status == "publishing"

    reset_at = System.system_time(:second) + 60

    Req.Test.stub(SuperX.X, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-rate-limit-reset", Integer.to_string(reset_at))
      |> Plug.Conn.send_resp(429, "")
    end)

    assert {:snooze, seconds} =
             PublishArticle.perform(%Oban.Job{
               args: %{"article_id" => article.id},
               attempt: 1
             })

    assert seconds in 1..60
    assert Repo.get!(Article, article.id).status == "publishing"
  end
end
