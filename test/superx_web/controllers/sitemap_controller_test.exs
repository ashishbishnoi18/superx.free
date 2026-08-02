defmodule SuperXWeb.SitemapControllerTest do
  use SuperXWeb.ConnCase, async: true

  test "lists only indexable public pages", %{conn: conn} do
    conn = get(conn, ~p"/sitemap.xml")
    body = response(conn, 200)

    assert get_resp_header(conn, "content-type") == ["application/xml; charset=utf-8"]
    assert body =~ "<loc>https://superx.free/</loc>"

    for private_path <- [
          "/home",
          "/api",
          "/analytics",
          "/contacts",
          "/share/",
          "/circle/",
          "/team/invitations/"
        ] do
      refute body =~ private_path
    end
  end
end
