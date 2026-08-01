defmodule SuperXWeb.AnalyticsShareController do
  use SuperXWeb, :controller

  alias SuperX.Analytics

  def show(conn, %{"token" => token}) do
    case Analytics.public_share(token) do
      nil ->
        send_resp(conn, 404, "Not found")

      public ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> assign(:page_title, "Shared analytics")
        |> assign(:public, public)
        |> render(:show, layout: false)
    end
  end
end
