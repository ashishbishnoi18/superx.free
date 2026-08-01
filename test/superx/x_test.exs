defmodule SuperX.XTest do
  use ExUnit.Case, async: true

  alias SuperX.X

  test "uses X's chunked GIF workflow and returns the fresh media id" do
    path = temporary_file(<<"GIF89a", 0, 0, 0, 0, 0, 0>>)
    counter = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(X, fn conn ->
      request = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      {body, conn} = read_body(conn)

      case request do
        1 ->
          assert body =~ ~s(name="command"\r\n\r\nINIT)
          assert body =~ ~s(name="media_category"\r\n\r\ntweet_gif)
          json(conn, 200, %{"data" => %{"id" => "x-media-1"}})

        2 ->
          assert body =~ ~s(name="command"\r\n\r\nAPPEND)
          assert body =~ "GIF89a"
          Plug.Conn.send_resp(conn, 204, "")

        3 ->
          assert body =~ ~s(name="command"\r\n\r\nFINALIZE)
          json(conn, 200, %{"data" => %{"id" => "x-media-1"}})
      end
    end)

    media = %{
      path: path,
      filename: "local.gif",
      content_type: "image/gif",
      size: File.stat!(path).size
    }

    assert {:ok, "x-media-1"} = X.upload_media("access-token", media)
    assert Agent.get(counter, & &1) == 3
  end

  defp temporary_file(contents) do
    path = Path.join(System.tmp_dir!(), "superx-x-upload-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp read_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {body, conn}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
