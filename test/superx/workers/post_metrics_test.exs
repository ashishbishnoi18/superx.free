defmodule SuperX.Workers.PostMetricsTest do
  @moduledoc """
  The fetch bills per tweet and the match decides which posts get fresh
  numbers, so the coverage is on the matching rules and on a failed
  account not taking the others down.
  """

  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.{Content, Repo}
  alias SuperX.Content.Post
  alias SuperX.Workers.PostMetrics

  describe "metrics_updates/2" do
    test "pairs a post with the metrics of its first X id" do
      post = %Post{x_post_ids: ["a", "b"]}

      tweets = [
        %{"id" => "b", "likeCount" => 5},
        %{
          "id" => "a",
          "likeCount" => 9,
          "viewCount" => 100,
          "retweetCount" => 2,
          "replyCount" => 1
        }
      ]

      assert [{^post, metrics}] = PostMetrics.metrics_updates([post], tweets)
      assert metrics == %{"likes" => 9, "views" => 100, "reposts" => 2, "replies" => 1}
    end

    test "skips posts whose ids are absent from the fetched tweets" do
      post = %Post{x_post_ids: ["gone"]}

      assert PostMetrics.metrics_updates([post], [%{"id" => "other"}]) == []
    end

    test "skips posts without X ids" do
      assert PostMetrics.metrics_updates([%Post{x_post_ids: []}], [%{"id" => "a"}]) == []
    end

    test "rejects incomplete metrics instead of treating unknown counts as zero" do
      post = %Post{x_post_ids: ["a"]}

      assert PostMetrics.metrics_updates([post], [%{"id" => "a"}]) == []
      assert PostMetrics.metrics_updates([post], [%{"id" => "a", "likeCount" => 0}]) == []
    end

    test "rejects non-numeric destructive metrics" do
      post = %Post{x_post_ids: ["a"]}

      tweet = %{"id" => "a", "likeCount" => 0, "viewCount" => "0"}
      assert PostMetrics.metrics_updates([post], [tweet]) == []
    end
  end

  describe "perform/1" do
    setup do
      previous = Application.get_env(:superx, SuperX.TwitterAPI, [])

      Application.put_env(
        :superx,
        SuperX.TwitterAPI,
        Keyword.merge(previous, api_key: "test-key", min_interval_ms: 0)
      )

      on_exit(fn -> Application.put_env(:superx, SuperX.TwitterAPI, previous) end)
      user_fixture()
    end

    test "stores metrics for posts matching the fetched tweets", %{
      user: user,
      account: account
    } do
      post = posted_post(user, account)
      stale = posted_post(user, account, published_at: days_ago(45))

      Req.Test.stub(SuperX.TwitterAPI, fn conn ->
        json(conn, %{"data" => %{"tweets" => [tweet(hd(post.x_post_ids))]}})
      end)

      assert :ok = PostMetrics.perform(%Oban.Job{})

      updated = Repo.get!(Post, post.id)
      assert updated.metrics == %{"likes" => 42, "views" => 1000, "reposts" => 5, "replies" => 3}
      assert %DateTime{} = updated.metrics_updated_at

      # Outside the lookback window: never matched, never refreshed.
      assert Repo.get!(Post, stale.id).metrics == %{}
    end

    test "a failed account does not stop the others", %{user: user, account: account} do
      %{user: other_user, account: other_account} = user_fixture()
      _failed_account_post = posted_post(user, account)
      other_post = posted_post(other_user, other_account)

      Req.Test.stub(SuperX.TwitterAPI, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.query_params["userName"] == account.handle do
          Plug.Conn.send_resp(conn, 402, ~s({"error":"out of credits"}))
        else
          json(conn, %{"data" => %{"tweets" => [tweet(hd(other_post.x_post_ids))]}})
        end
      end)

      assert :ok = PostMetrics.perform(%Oban.Job{})

      assert Repo.get!(Post, other_post.id).metrics["likes"] == 42
    end
  end

  defp posted_post(user, account, attrs \\ %{}) do
    {:ok, post} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "hello", "media_ids" => []}],
        status: "draft"
      })

    {:ok, post} = Content.mark_published(post, ["x-#{System.unique_integer([:positive])}"])

    if attrs == %{} do
      post
    else
      post |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end
  end

  defp tweet(x_post_id) do
    %{
      "id" => x_post_id,
      "text" => "hello",
      "createdAt" => "Wed Oct 10 20:19:24 +0000 2018",
      "likeCount" => 42,
      "viewCount" => 1000,
      "retweetCount" => 5,
      "replyCount" => 3,
      "author" => %{"userName" => "someone", "name" => "Someone"}
    }
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp days_ago(days) do
    DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second) |> DateTime.truncate(:second)
  end
end
