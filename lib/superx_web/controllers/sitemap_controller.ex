defmodule SuperXWeb.SitemapController do
  use SuperXWeb, :controller

  @public_urls ["https://superx.free/"]

  def index(conn, _params) do
    urls = Enum.map_join(@public_urls, "\n", &url_entry/1)

    body = """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{urls}
    </urlset>
    """

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(:ok, body)
  end

  defp url_entry(url) do
    """
      <url>
        <loc>#{url}</loc>
      </url>
    """
  end
end
