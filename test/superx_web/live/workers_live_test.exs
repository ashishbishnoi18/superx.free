defmodule SuperXWeb.WorkersLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Oban.Testing
  import SuperX.Fixtures

  alias SuperX.{AI, Accounts, Workers}
  alias SuperX.Workers.RunContentWorker

  setup %{conn: conn} do
    previous = Application.get_env(:superx, AI, [])

    Application.put_env(
      :superx,
      AI,
      Keyword.merge(previous, api_key: "test-key", base_url: "https://api.anthropic.test")
    )

    on_exit(fn -> Application.put_env(:superx, AI, previous) end)

    %{user: user, account: account} = user_fixture()
    {:ok, token} = Accounts.create_session(user)

    %{conn: init_test_session(conn, %{user_token: token}), user: user, account: account}
  end

  test "shows a specific empty state and opens the worker form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workers")

    assert has_element?(view, "#workers-empty")
    assert has_element?(view, "a[href='/workers'][aria-current='page']")

    view |> element("#new-worker") |> render_click()

    assert has_element?(view, "#worker-form")
    assert has_element?(view, "#content_worker_topic_source")
  end

  test "creates, edits, disables, and enables a product worker", %{
    conn: conn,
    account: account
  } do
    {:ok, view, _html} = live(conn, ~p"/workers")
    view |> element("#new-worker") |> render_click()

    params = %{
      "name" => "Product notes",
      "topic_source" => "products",
      "product_context" => "A private analytics workspace for small teams.",
      "batch_size" => "4",
      "enabled" => "true",
      "cadence" => "weekly",
      "schedule_day" => "2",
      "schedule_time" => "09:30"
    }

    view
    |> form("#worker-form",
      content_worker:
        Map.take(params, ["name", "topic_source", "batch_size", "enabled", "cadence"])
    )
    |> render_change()

    assert has_element?(view, "#content_worker_product_context")

    view |> form("#worker-form", content_worker: params) |> render_submit()

    [worker] = Workers.list_content_workers(account)
    assert worker.product_context == params["product_context"]
    assert worker.batch_size == 4
    assert has_element?(view, "#worker-#{worker.id}")
    assert has_element?(view, "#run-worker-#{worker.id}")

    view
    |> element("[phx-click='edit'][phx-value-id='#{worker.id}']")
    |> render_click()

    view
    |> form("#worker-form", content_worker: Map.put(params, "name", "Launch notes"))
    |> render_submit()

    assert Workers.list_content_workers(account) |> hd() |> Map.fetch!(:name) == "Launch notes"

    view
    |> element("[phx-click='toggle'][phx-value-id='#{worker.id}']")
    |> render_click()

    refute Workers.list_content_workers(account) |> hd() |> Map.fetch!(:enabled)

    view
    |> element("[phx-click='toggle'][phx-value-id='#{worker.id}']")
    |> render_click()

    assert Workers.list_content_workers(account) |> hd() |> Map.fetch!(:enabled)
  end

  test "runs a manual batch immediately and shows it in progress", %{
    conn: conn,
    user: user,
    account: account
  } do
    test_pid = self()

    Req.Test.stub(AI, fn conn ->
      send(test_pid, {:generation_started, self()})

      receive do
        :finish_generation -> writer_reply(conn, "The finished draft.")
      end
    end)

    {:ok, worker} =
      Workers.create_content_worker(user, account, %{
        name: "Product notes",
        topic_source: "products",
        product_context: "A private analytics workspace for small teams.",
        batch_size: 1
      })

    {:ok, view, _html} = live(conn, ~p"/workers")

    view |> element("#run-worker-#{worker.id}") |> render_click()

    assert_receive {:generation_started, task_pid}
    assert has_element?(view, "#run-worker-#{worker.id}[disabled]", "Writing…")

    refute_enqueued(
      repo: SuperX.Repo,
      worker: RunContentWorker,
      args: %{"content_worker_id" => worker.id}
    )

    ref = Process.monitor(task_pid)
    send(task_pid, :finish_generation)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, :normal}
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#flash-info", "Wrote 1 draft. It's ready to review.")
    refute has_element?(view, "#run-worker-#{worker.id}[disabled]")
  end

  test "reports a partial batch and its returned credits", %{
    conn: conn,
    user: user,
    account: account
  } do
    {:ok, worker} =
      Workers.create_content_worker(user, account, %{
        name: "Product notes",
        topic_source: "products",
        product_context: "A private analytics workspace for small teams.",
        batch_size: 5
      })

    {:ok, view, _html} = live(conn, ~p"/workers")

    send(
      view.pid,
      {:worker_finished, worker.id,
       %{
         status: :error,
         generated: 2,
         failed: 3,
         requested: 5,
         reason: {:generation_failed, 3}
       }}
    )

    assert has_element?(
             view,
             "#flash-error",
             "Wrote 2 of 5 drafts. 3 failed, and their credits were returned."
           )
  end

  test "explains a worker run that cannot produce any drafts", %{
    conn: conn,
    user: user,
    account: account
  } do
    {:ok, worker} =
      Workers.create_content_worker(user, account, %{
        name: "Voice ideas",
        topic_source: "voice",
        batch_size: 3
      })

    {:ok, view, _html} = live(conn, ~p"/workers")

    send(
      view.pid,
      {:worker_finished, worker.id,
       %{status: :error, generated: 0, failed: 3, requested: 3, reason: :no_topics}}
    )

    assert has_element?(
             view,
             "#flash-error",
             "No drafts were written. Add topics or published posts in Voice, then run again."
           )
  end

  defp writer_reply(conn, text) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "content" => [
          %{
            "type" => "tool_use",
            "name" => "respond",
            "input" => %{"segments" => [text]}
          }
        ]
      })
    )
  end
end
