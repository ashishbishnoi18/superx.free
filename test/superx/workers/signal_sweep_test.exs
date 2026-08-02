defmodule SuperX.Workers.SignalSweepTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.{Billing, Repo, Signals, TwitterAPI}
  alias SuperX.Workers.SignalSweep

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

    :ok
  end

  test "a daily lead cap is visible but does not permanently pause the agent" do
    %{user: user, account: account} = user_fixture()
    {:ok, _subscription} = Billing.upsert_subscription(user, %{tier: "pro", status: "active"})
    {:ok, agent} = Signals.create_agent(account, %{kind: "keyword", target: "founders"})

    quota = Billing.get_quota(user, "leads_day")
    assert {:ok, _quota} = Billing.claim(user, "leads_day", quota.limit)

    Req.Test.stub(TwitterAPI, fn _conn ->
      flunk("an exhausted daily quota must be checked before making a billable read")
    end)

    assert {:error, :quota_exceeded, %{resets_at: _resets_at}} =
             agent |> Repo.preload(:x_account) |> SignalSweep.run_agent()

    reloaded = Signals.get_agent(account, agent.id)
    assert reloaded.enabled
    assert reloaded.last_error =~ "Daily lead quota reached"
    assert reloaded.last_run_at
  end

  test "a run keeps only the number of leads remaining in today's quota" do
    %{user: user, account: account} = user_fixture()
    {:ok, _subscription} = Billing.upsert_subscription(user, %{tier: "pro", status: "active"})
    {:ok, agent} = Signals.create_agent(account, %{kind: "keyword", target: "quota-edge"})

    quota = Billing.get_quota(user, "leads_day")
    assert {:ok, _quota} = Billing.claim(user, "leads_day", quota.limit - 1)

    Req.Test.stub(TwitterAPI, fn conn ->
      tweets = [tweet("first"), tweet("second")]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"tweets" => tweets, "has_next_page" => false})
      )
    end)

    assert {:ok, 1} = agent |> Repo.preload(:x_account) |> SignalSweep.run_agent()
    assert length(Signals.list_leads(account)) == 1
    assert Billing.get_quota(user, "leads_day").used == quota.limit
    assert Signals.get_agent(account, agent.id).last_error =~ "Daily lead quota reached"
  end

  defp tweet(handle) do
    %{
      "id" => "post-#{handle}",
      "text" => "A relevant post",
      "author" => %{"id" => handle, "userName" => handle, "name" => String.capitalize(handle)}
    }
  end
end
