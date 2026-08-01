defmodule SuperXWeb.AnalyticsShareControllerTest do
  use SuperXWeb.ConnCase, async: true

  import SuperX.Fixtures

  alias SuperX.{Analytics, Content}

  test "serves only the shared summary without authentication and stops after revocation", %{
    conn: conn
  } do
    %{user: user, account: account} = user_fixture(display_name: "Public Account")
    today = Date.utc_today()
    from = Date.add(today, -7)

    {:ok, _} =
      Analytics.record_snapshot(account, from, %{followers: 100, following: 50, posts: 8})

    {:ok, _} =
      Analytics.record_snapshot(account, today, %{
        followers: 110,
        following: 50,
        posts: 10,
        impressions: 900,
        engagements: 45
      })

    {:ok, secret_post} =
      Content.create_post(user, account, %{
        status: "draft",
        segments: [%{"text" => "internal post text must not appear"}]
      })

    {:ok, _secret_post} = Content.mark_published(secret_post, ["secret"])
    {:ok, share} = Analytics.create_share(account, from, today)

    conn = get(conn, ~p"/share/#{share.token}")
    html = html_response(conn, 200)

    assert html =~ "shared-analytics"
    assert html =~ "Public Account"
    assert html =~ "900"
    refute html =~ "internal post text must not appear"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]

    :ok = Analytics.revoke_share(account)
    assert get(build_conn(), ~p"/share/#{share.token}") |> response(404) == "Not found"
  end

  test "returns the same 404 for an unknown capability", %{conn: conn} do
    assert get(conn, ~p"/share/not-a-real-share") |> response(404) == "Not found"
  end
end
