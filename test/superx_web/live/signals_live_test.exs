defmodule SuperXWeb.SignalsLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Signals}

  test "an existing agent can change where future contacts are filed", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, token} = Accounts.create_session(user)
    conn = init_test_session(conn, %{user_token: token})

    {:ok, list} = Signals.create_contact_list(account, %{name: "Prospects"})
    {:ok, agent} = Signals.create_agent(account, %{kind: "keyword", target: "postgres"})
    {:ok, view, _html} = live(conn, ~p"/signals")

    view
    |> form("#agent-list-form-#{agent.id}", filing: %{contact_list_id: list.id})
    |> render_change()

    assert Signals.get_agent(account, agent.id).contact_list_id == list.id
  end

  test "creating an agent starts its first run immediately", %{conn: conn} do
    %{user: user, account: account} = user_fixture()

    {:ok, _subscription} =
      SuperX.Billing.upsert_subscription(user, %{tier: "pro", status: "active"})

    {:ok, token} = Accounts.create_session(user)
    conn = init_test_session(conn, %{user_token: token})

    previous_twitter = Application.get_env(:superx, SuperX.TwitterAPI, [])
    previous_ai = Application.get_env(:superx, SuperX.AI, [])

    Application.put_env(
      :superx,
      SuperX.TwitterAPI,
      Keyword.merge(previous_twitter, api_key: "test-key", min_interval_ms: 0)
    )

    Application.put_env(:superx, SuperX.AI, Keyword.put(previous_ai, :api_key, nil))

    on_exit(fn ->
      Application.put_env(:superx, SuperX.TwitterAPI, previous_twitter)
      Application.put_env(:superx, SuperX.AI, previous_ai)
    end)

    test_pid = self()

    Req.Test.stub(SuperX.TwitterAPI, fn request ->
      send(test_pid, {:signal_request, self(), request.request_path})

      receive do
        :continue ->
          body = %{
            "tweets" => [
              %{
                "id" => "first-run-post",
                "text" => "Phoenix is useful",
                "author" => %{"userName" => "firstmatch", "name" => "First Match"}
              }
            ],
            "has_next_page" => false
          }

          request
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/signals")
    followers = Enum.find(Signals.list_contact_lists(account), &(&1.kind == "followers"))

    view
    |> form("#signal-agent-form",
      agent: %{
        kind: "keyword",
        target: "immediate-first-run",
        ideal_customer: "",
        min_score: "60",
        contact_list_id: followers.id
      }
    )
    |> render_submit()

    assert_receive {:signal_request, task_pid, "/twitter/tweet/advanced_search"}
    task_ref = Process.monitor(task_pid)

    agent = Enum.find(Signals.list_agents(account), &(&1.target == "immediate-first-run"))
    assert has_element?(view, "#signal-agent-#{agent.id}", "Running…")

    send(task_pid, :continue)
    assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :normal}
    _ = :sys.get_state(view.pid)

    assert [%{handle: "firstmatch"}] = Signals.list_leads(account)
    assert Signals.get_agent(account, agent.id).last_run_at
    assert has_element?(view, "#signal-agent-#{agent.id}", "1 found")
  end
end
