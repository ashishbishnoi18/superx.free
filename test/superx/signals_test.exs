defmodule SuperX.SignalsTest do
  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.Signals
  alias SuperX.Signals.Agent

  setup do
    user_fixture()
  end

  defp lead(account, handle, overrides) do
    Map.merge(
      %{
        x_account_id: account.id,
        handle: handle,
        display_name: handle,
        followers_count: 1000,
        score: 70
      },
      overrides
    )
  end

  describe "agents" do
    test "normalises a handle however it was pasted", %{account: account} do
      for target <- ["@levelsio", "levelsio", "https://x.com/levelsio", "twitter.com/levelsio/"] do
        {:ok, agent} =
          Signals.create_agent(account, %{kind: "follower", target: target})

        assert agent.target == "levelsio"
        Signals.delete_agent(account, agent.id)
      end
    end

    test "leaves a keyword target alone", %{account: account} do
      {:ok, agent} =
        Signals.create_agent(account, %{kind: "keyword", target: "\"build in public\""})

      assert agent.target == "\"build in public\""
    end

    test "names itself from what it watches", %{account: account} do
      {:ok, agent} = Signals.create_agent(account, %{kind: "follower", target: "@levelsio"})
      assert agent.name == "Followers of @levelsio"
      assert Agent.describes(agent) == "new followers of @levelsio"
    end

    test "describes a list watch as active authors rather than every list member", %{
      account: account
    } do
      {:ok, agent} = Signals.create_agent(account, %{kind: "list", target: "12345"})

      assert agent.name == "Activity in list 12345"
      assert Agent.describes(agent) == "people posting in list 12345"
    end

    test "rejects an out-of-range minimum score", %{account: account} do
      assert {:error, changeset} =
               Signals.create_agent(account, %{kind: "keyword", target: "x", min_score: 140})

      assert errors_on(changeset)[:min_score]
    end

    test "agents_due excludes recently run ones", %{account: account} do
      {:ok, fresh} = Signals.create_agent(account, %{kind: "keyword", target: "fresh"})
      {:ok, _stale} = Signals.create_agent(account, %{kind: "keyword", target: "stale"})

      {:ok, _} = Signals.record_run(fresh, 3)

      targets = Signals.agents_due() |> Enum.map(& &1.target)
      assert "stale" in targets
      refute "fresh" in targets
    end

    test "record_run accumulates the running total", %{account: account} do
      {:ok, agent} = Signals.create_agent(account, %{kind: "keyword", target: "x"})

      {:ok, agent} = Signals.record_run(agent, 3)
      {:ok, agent} = Signals.record_run(agent, 4)

      assert agent.leads_found == 7
    end
  end

  describe "lead deduplication" do
    test "the same person from two watches is one lead", %{account: account} do
      assert {1, _} = Signals.upsert_leads([lead(account, "someone", %{score: 60})])
      assert {1, _} = Signals.upsert_leads([lead(account, "someone", %{score: 90})])

      assert [only] = Signals.list_leads(account)
      assert only.handle == "someone"
    end

    test "keeps the higher score when a weaker watch runs later", %{account: account} do
      Signals.upsert_leads([lead(account, "someone", %{score: 90})])
      Signals.upsert_leads([lead(account, "someone", %{score: 20})])

      assert [%{score: 90}] = Signals.list_leads(account)
    end

    test "refreshes reach and bio on a re-find", %{account: account} do
      Signals.upsert_leads([lead(account, "someone", %{followers_count: 100, bio: "old"})])
      Signals.upsert_leads([lead(account, "someone", %{followers_count: 5000, bio: "new"})])

      assert [%{followers_count: 5000, bio: "new"}] = Signals.list_leads(account)
    end

    test "collapses duplicates within one batch", %{account: account} do
      assert {1, _} =
               Signals.upsert_leads([
                 lead(account, "someone", %{}),
                 lead(account, "SOMEONE", %{})
               ])
    end

    test "known_handles is case-insensitive so a re-find is not re-scored", %{account: account} do
      Signals.upsert_leads([lead(account, "SomeOne", %{})])

      known = Signals.known_handles(account)
      assert MapSet.member?(known, "someone")
    end
  end

  describe "lead lifecycle" do
    test "orders by score", %{account: account} do
      Signals.upsert_leads([
        lead(account, "weak", %{score: 30}),
        lead(account, "strong", %{score: 95})
      ])

      assert [%{handle: "strong"}, %{handle: "weak"}] = Signals.list_leads(account)
    end

    test "marking contacted stamps the time once", %{account: account} do
      Signals.upsert_leads([lead(account, "someone", %{})])
      [l] = Signals.list_leads(account)

      {:ok, contacted} = Signals.set_lead_status(l, "contacted")
      assert contacted.status == "contacted"
      assert contacted.contacted_at

      # Moving on shouldn't rewrite when they were first contacted.
      {:ok, replied} = Signals.set_lead_status(contacted, "replied")
      assert replied.contacted_at == contacted.contacted_at
    end

    test "counts per status", %{account: account} do
      Signals.upsert_leads([lead(account, "a", %{}), lead(account, "b", %{})])
      [first | _] = Signals.list_leads(account)
      {:ok, _} = Signals.set_lead_status(first, "contacted")

      counts = Signals.lead_counts(account)
      assert counts["new"] == 1
      assert counts["contacted"] == 1
      assert counts["all"] == 2
    end
  end

  describe "plan limits" do
    test "the agent limit comes from the plan", %{user: user} do
      # Free includes no agents; that's what pushes the upgrade prompt.
      assert Signals.agent_limit(user) == 0

      {:ok, _} = SuperX.Billing.upsert_subscription(user, %{tier: "pro", status: "active"})
      assert Signals.agent_limit(user) == 1
    end
  end
end
