defmodule SuperXWeb.WorkersLiveTest do
  use SuperXWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Workers}

  setup %{conn: conn} do
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
end
