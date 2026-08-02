defmodule SuperXWeb.RobotsTest do
  use SuperXWeb.ConnCase, async: true

  test "allows search and AI crawlers without exposing private routes", %{conn: conn} do
    conn = get(conn, ~p"/robots.txt")
    body = response(conn, 200)

    assert get_resp_header(conn, "content-type") == ["text/plain"]

    for crawler <- ["*", "GPTBot", "ClaudeBot", "PerplexityBot", "Google-Extended", "CCBot"] do
      assert body =~ "User-agent: #{crawler}"
    end

    for private_path <- [
          "/accounts",
          "/analytics",
          "/api",
          "/auth",
          "/circle/",
          "/contacts",
          "/home",
          "/share/",
          "/team/invitations/",
          "/uploads"
        ] do
      assert body =~ "Disallow: #{private_path}"
    end

    assert body =~ "Sitemap: https://superx.free/sitemap.xml"
  end
end
