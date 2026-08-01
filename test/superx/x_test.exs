defmodule SuperX.XTest do
  use ExUnit.Case, async: false

  alias SuperX.X

  setup do
    previous = Application.get_env(:superx, X, [])

    Application.put_env(
      :superx,
      X,
      Keyword.merge(previous,
        api_base: "https://api.x.com/2",
        client_id: "client-id",
        client_secret: "client-secret",
        redirect_uri: "https://superx.test/auth/x/callback",
        scopes: ~w(tweet.read tweet.write users.read offline.access)
      )
    )

    on_exit(fn -> Application.put_env(:superx, X, previous) end)
    :ok
  end

  describe "DM OAuth gating" do
    test "keeps the existing OAuth scopes when the flag is off" do
      configure_dms(false)

      assert oauth_scopes() == ~w(tweet.read tweet.write users.read offline.access)
    end

    test "adds both required DM scopes only when the flag is on" do
      configure_dms(true)

      assert oauth_scopes() ==
               ~w(tweet.read tweet.write users.read offline.access dm.read dm.write)
    end
  end

  describe "create_dm/3" do
    test "uses X's OAuth one-to-one endpoint and normalises its ids" do
      Req.Test.stub(X, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/2/dm_conversations/with/7788/messages"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer user-token"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"text" => "A considered reply"}

        response = %{
          "data" => %{
            "dm_conversation_id" => "11-7788",
            "dm_event_id" => "event-1"
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(201, Jason.encode!(response))
      end)

      assert {:ok, %{conversation_id: "11-7788", message_id: "event-1"}} =
               X.create_dm("user-token", "7788", "A considered reply")
    end
  end

  defp configure_dms(enabled) do
    config = Application.get_env(:superx, X, [])
    Application.put_env(:superx, X, Keyword.put(config, :dm_enabled, enabled))
  end

  defp oauth_scopes do
    X.authorize_url("state", "challenge")
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("scope")
    |> String.split()
  end
end
