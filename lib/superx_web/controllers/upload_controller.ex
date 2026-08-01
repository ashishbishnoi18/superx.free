defmodule SuperXWeb.UploadController do
  use SuperXWeb, :controller

  alias SuperX.Media

  def show(conn, %{"id" => id}) do
    case Media.file(id) do
      {:ok, media} ->
        conn
        |> put_resp_content_type(media.content_type)
        |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
        |> send_file(200, media.path)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")
    end
  end
end
