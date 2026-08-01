defmodule SuperXWeb.ContactListShareController do
  use SuperXWeb, :controller

  alias SuperX.Signals

  def show(conn, %{"token" => token} = params) do
    case Signals.public_contact_list_share(token, page: page(params["page"])) do
      nil ->
        send_resp(conn, 404, "Not found")

      public ->
        conn
        |> put_resp_header("cache-control", "private, no-store")
        |> assign(:page_title, public.list.name)
        |> assign(:token, token)
        |> assign(:public, public)
        |> render(:show, layout: false)
    end
  end

  defp page(nil), do: 1

  defp page(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end
end
