defmodule SuperX.SignalScoutTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.{Signals, TwitterAPI}
  alias SuperX.Signals.Scout

  setup do
    previous_twitter = Application.get_env(:superx, TwitterAPI, [])
    previous_ai = Application.get_env(:superx, SuperX.AI, [])

    Application.put_env(
      :superx,
      TwitterAPI,
      Keyword.merge(previous_twitter, api_key: "test-key", min_interval_ms: 0)
    )

    Application.put_env(:superx, SuperX.AI, Keyword.put(previous_ai, :api_key, nil))

    on_exit(fn ->
      Application.put_env(:superx, TwitterAPI, previous_twitter)
      Application.put_env(:superx, SuperX.AI, previous_ai)
    end)

    user_fixture()
  end

  test "files an already-known match in the agent's selected list", %{account: account} do
    {:ok, list} = Signals.create_contact_list(account, %{name: "Partners"})

    Signals.upsert_leads([
      %{x_account_id: account.id, handle: "known", display_name: "Known contact", score: 80}
    ])

    {:ok, agent} =
      Signals.create_agent(account, %{
        kind: "keyword",
        target: "known-person-query",
        contact_list_id: list.id
      })

    stub_tweets([tweet("known")])

    assert {:ok, 0} = agent |> Repo.preload(:x_account) |> Scout.run()
    assert [%{handle: "known"}] = Signals.list_leads(account, list: list)
  end

  test "marks fallback scores as not AI-judged when no LLM is configured", %{account: account} do
    {:ok, agent} =
      Signals.create_agent(account, %{
        kind: "keyword",
        target: "unscored-person-query",
        ideal_customer: "Elixir founders",
        min_score: 70
      })

    stub_tweets([tweet("unscored")])

    assert {:ok, 1} = agent |> Repo.preload(:x_account) |> Scout.run()

    assert [%{score: 70, reason: "Not AI-scored: no LLM is configured."}] =
             Signals.list_leads(account)
  end

  test "surfaces a total reply-fetch failure instead of reporting no matches", %{account: account} do
    {:ok, agent} = Signals.create_agent(account, %{kind: "profile", target: "someone"})

    Req.Test.stub(TwitterAPI, fn conn ->
      case conn.request_path do
        "/twitter/user/last_tweets" ->
          json(conn, %{"data" => %{"tweets" => [%{"id" => "post-1"}]}})

        "/twitter/tweet/replies" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "upstream unavailable"}))
      end
    end)

    assert {:error, {:http_error, 500, _body}} =
             agent |> Repo.preload(:x_account) |> Scout.run()
  end

  defp stub_tweets(tweets) do
    Req.Test.stub(TwitterAPI, fn conn ->
      assert conn.request_path == "/twitter/tweet/advanced_search"
      json(conn, %{"tweets" => tweets, "has_next_page" => false})
    end)
  end

  defp tweet(handle) do
    %{
      "id" => "post-#{handle}",
      "text" => "A relevant post",
      "author" => %{
        "id" => "user-#{handle}",
        "userName" => handle,
        "name" => String.capitalize(handle),
        "description" => "Elixir founder",
        "followers" => 100,
        "following" => 50
      }
    }
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
