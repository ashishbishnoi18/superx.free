defmodule SuperXWeb.AnalyticsLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Analytics}

  setup %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, token} = Accounts.create_session(user)
    conn = init_test_session(conn, %{user_token: token})

    %{conn: conn, account: account}
  end

  test "reports exactly what a history upload imported and skipped", %{
    conn: conn,
    account: account
  } do
    today = Date.utc_today()

    {:ok, _} =
      Analytics.record_snapshot(account, today, %{followers: 100, following: 50, posts: 10})

    csv =
      "Date,Followers,Total Posts,Impressions\n" <>
        "#{Date.add(today, -1)},95,9,500\n" <>
        "#{today},999,999,999\n"

    {:ok, view, _html} = live(conn, ~p"/analytics")

    upload =
      file_input(view, "#analytics-history-form", :history, [
        %{name: "analytics.csv", content: csv, type: "text/csv"}
      ])

    render_upload(upload, "analytics.csv")
    view |> element("#analytics-history-form") |> render_submit()

    assert has_element?(view, "#analytics-import-report", "Imported 1 date")
    assert has_element?(view, "#analytics-import-report", "Skipped 1 already recorded")
  end

  test "creates and turns off a public summary", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/analytics")

    view |> element("button[phx-click=create_share]") |> render_click()
    assert has_element?(view, "#analytics-share a[href^=\"http://\"]")

    view |> element("#analytics-share button[phx-click=revoke_share]") |> render_click()
    refute has_element?(view, "#analytics-share")
  end
end
