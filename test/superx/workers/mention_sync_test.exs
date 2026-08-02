defmodule SuperX.Workers.MentionSyncTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.Engage
  alias SuperX.Workers.MentionSync

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

  test "does not drop mentions after the old free-tier batch ceiling", %{account: account} do
    tweets = Enum.map(1..30, &tweet/1)

    Req.Test.stub(SuperX.TwitterAPI, fn conn ->
      json(conn, %{"tweets" => tweets, "has_next_page" => false})
    end)

    assert {:ok, 30} = MentionSync.sync_mentions(account)
    assert Engage.counts(account)["mention"] == 30
  end

  test "a later feed sync asks upstream for posts since the prior sync", %{account: account} do
    calls = start_supervised!({Agent, fn -> [] end})
    query = "cache-boundary-#{System.unique_integer([:positive])}"
    {:ok, feed} = Engage.create_feed(account, %{query: query})

    Req.Test.stub(SuperX.TwitterAPI, fn conn ->
      params = Plug.Conn.fetch_query_params(conn).query_params
      Agent.update(calls, &[params["query"] | &1])
      json(conn, %{"tweets" => [], "has_next_page" => false})
    end)

    assert {:ok, 0} = MentionSync.sync_feed(%{feed | x_account: account})

    refreshed = Engage.get_feed(account, feed.id)
    assert {:ok, 0} = MentionSync.sync_feed(%{refreshed | x_account: account})

    [second_query, first_query] = Agent.get(calls, & &1)
    refute first_query =~ "since_time:"
    assert second_query =~ "since_time:"
  end

  test "view counts come along with the rest of the mention metrics", %{account: account} do
    tweet = %{
      "id" => "viewed-mention",
      "text" => "loved the post",
      "createdAt" => "Wed Oct 10 20:19:24 +0000 2018",
      "viewCount" => 12_345,
      "author" => %{
        "userName" => "fan",
        "name" => "Fan",
        "followers" => 10,
        "isBlueVerified" => true
      }
    }

    Req.Test.stub(SuperX.TwitterAPI, fn conn ->
      json(conn, %{"tweets" => [tweet], "has_next_page" => false})
    end)

    assert {:ok, 1} = MentionSync.sync_mentions(account)
    assert [%{views: 12_345, author_verified: true}] = Engage.list_engagements(account)
  end

  defp tweet(number) do
    %{
      "id" => "burst-#{number}",
      "text" => "mention #{number}",
      "createdAt" => "Wed Oct 10 20:19:24 +0000 2018",
      "author" => %{
        "userName" => "person#{number}",
        "name" => "Person #{number}",
        "followers" => 100
      }
    }
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
