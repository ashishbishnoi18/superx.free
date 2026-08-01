defmodule SuperX.Workers.RunContentWorkerTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.{Billing, Content, Repo, Workers}
  alias SuperX.AI
  alias SuperX.Billing.Quota
  alias SuperX.Workers.{RunContentWorker, ShelfTopUp}

  setup do
    previous = Application.get_env(:superx, AI, [])

    Application.put_env(
      :superx,
      AI,
      Keyword.merge(previous,
        api_key: "test-key",
        base_url: "https://api.anthropic.com",
        writer_model: "test-writer"
      )
    )

    on_exit(fn -> Application.put_env(:superx, AI, previous) end)

    fixture = user_fixture()
    voice = Content.get_voice_profile(fixture.account)

    {:ok, _voice} =
      Content.update_voice_profile(voice, %{
        about: "I build careful software products.",
        topics: "developer tools, product design"
      })

    fixture
  end

  test "writes exactly the configured batch and charges one credit per shelf item", %{
    user: user,
    account: account
  } do
    calls = :counters.new(1, [])
    stub_writer(calls)

    {:ok, worker} = product_worker(user, account, 3)
    before = Billing.credit_balance(user)

    assert {:ok, 3} = RunContentWorker.run_batch(worker)
    assert length(Content.list_shelf(account)) == 3
    assert Billing.credit_balance(user) == before - 3
    assert :counters.get(calls, 1) == 3
    assert %DateTime{} = Repo.reload!(worker).last_run_at
  end

  test "stops at quota exhaustion instead of attempting the rest of the batch", %{
    user: user,
    account: account
  } do
    calls = :counters.new(1, [])
    stub_writer(calls)

    quota = Billing.get_quota(user, "credits_month")
    quota |> Quota.changeset(%{used: quota.limit - 2}) |> Repo.update!()

    {:ok, worker} = product_worker(user, account, 5)

    assert {:ok, 2} = RunContentWorker.run_batch(worker)
    assert length(Content.list_shelf(account)) == 2
    assert Billing.credit_balance(user) == 0
    assert :counters.get(calls, 1) == 2
  end

  test "uses an account's own published post for the voice source", %{
    user: user,
    account: account
  } do
    {:ok, post} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "The useful part of a launch is learning where buyers hesitate."}],
        status: "draft"
      })

    {:ok, _published} = Content.mark_published(post, ["voice-source"])

    calls = :counters.new(1, [])

    stub_writer(calls, fn prompt ->
      assert prompt =~ "The useful part of a launch is learning where buyers hesitate."
      refute prompt =~ "<reference_post>"
    end)

    {:ok, worker} =
      Workers.create_content_worker(user, account, %{
        name: "Voice builder",
        topic_source: "voice",
        batch_size: 1
      })

    assert {:ok, 1} = RunContentWorker.run_batch(worker)
    assert [%{source_corpus_post_id: nil, kind: "for_you"}] = Content.list_shelf(account)
  end

  test "uses a recent niche corpus post for the trends source", %{
    user: user,
    account: account
  } do
    source_text =
      "Good developer tools disappear into the work. The strongest products shorten the loop " <>
        "between noticing a problem and testing the fix, without asking the engineer to change context."

    source = corpus_post_fixture(%{text: source_text, topics: ["developer tools"]})
    calls = :counters.new(1, [])

    stub_writer(calls, fn prompt ->
      assert prompt =~ "<reference_post>"
      assert prompt =~ source_text
    end)

    {:ok, worker} =
      Workers.create_content_worker(user, account, %{
        name: "Trend builder",
        topic_source: "trends",
        batch_size: 1
      })

    assert {:ok, 1} = RunContentWorker.run_batch(worker)

    assert [%{source_corpus_post_id: source_id, kind: "trending"}] =
             Content.list_shelf(account)

    assert source_id == source.id
  end

  test "keeps the nightly shelf top-up for an account without configured workers", %{
    account: account
  } do
    calls = :counters.new(1, [])
    stub_writer(calls)

    assert :ok = ShelfTopUp.perform(%Oban.Job{args: %{"x_account_id" => account.id}})
    assert length(Content.list_shelf(account)) == 12
    assert :counters.get(calls, 1) == 12
  end

  test "does not second-guess a disabled configured worker with the nightly fallback", %{
    user: user,
    account: account
  } do
    calls = :counters.new(1, [])
    stub_writer(calls)

    assert {:ok, _worker} =
             Workers.create_content_worker(user, account, %{
               name: "Paused on purpose",
               topic_source: "voice",
               batch_size: 2,
               enabled: false
             })

    assert :ok = ShelfTopUp.perform(%Oban.Job{args: %{"x_account_id" => account.id}})
    assert Content.list_shelf(account) == []
    assert :counters.get(calls, 1) == 0
  end

  defp product_worker(user, account, batch_size) do
    Workers.create_content_worker(user, account, %{
      name: "Product builder",
      topic_source: "products",
      product_context: "A self-hosted writing tool for people building in public.",
      batch_size: batch_size
    })
  end

  defp stub_writer(calls, assert_prompt \\ fn _prompt -> :ok end) do
    Req.Test.stub(AI, fn conn ->
      :counters.add(calls, 1, 1)
      number = :counters.get(calls, 1)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      prompt = body |> Jason.decode!() |> get_in(["messages", Access.at(0), "content"])
      assert_prompt.(prompt)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "content" => [
            %{
              "type" => "tool_use",
              "name" => "respond",
              "input" => %{"segments" => ["Draft number #{number} with a concrete point."]}
            }
          ]
        })
      )
    end)
  end
end
