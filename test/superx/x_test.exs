defmodule SuperX.XTest do
  @moduledoc """
  The user-authenticated X boundary. Media ids and private message calls fail
  publicly when their wire format drifts, so they are pinned here.
  """

  # Not async: the scope tests swap application config.
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

  describe "upload_media/2" do
    test "uses X's chunked GIF workflow and returns the fresh media id" do
      path = temporary_file(<<"GIF89a", 0, 0, 0, 0, 0, 0>>)
      counter = start_supervised!({Agent, fn -> 0 end})

      # v2 gives each step its own path rather than a `command` parameter.
      # Pinned against the wire because the v1.1 shape survives INIT and
      # only fails at APPEND, which no stub caught until it ran for real.
      Req.Test.stub(X, fn conn ->
        request = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
        {body, conn} = read_body(conn)

        case request do
          1 ->
            assert conn.request_path == "/2/media/upload/initialize"
            assert Jason.decode!(body)["media_category"] == "tweet_gif"
            assert Jason.decode!(body)["total_bytes"] == 12
            json(conn, 200, %{"data" => %{"id" => "x-media-1"}})

          2 ->
            assert conn.request_path == "/2/media/upload/x-media-1/append"
            assert body =~ ~s(name="segment_index")
            assert body =~ "GIF89a"
            Plug.Conn.send_resp(conn, 204, "")

          3 ->
            assert conn.request_path == "/2/media/upload/x-media-1/finalize"
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

  describe "conversation event reads" do
    test "uses both supported conversation lookup paths" do
      Req.Test.stub(X, fn conn ->
        assert conn.method == "GET"

        assert conn.request_path in [
                 "/2/dm_conversations/with/7788/dm_events",
                 "/2/dm_conversations/11-7788/dm_events"
               ]

        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer user-token"]
        json(conn, 200, %{"meta" => %{"result_count" => 0}})
      end)

      assert {:ok, %{events: [], users: %{}}} =
               X.get_dm_events_with_participant("user-token", "7788")

      assert {:ok, %{events: [], users: %{}}} =
               X.get_dm_conversation_events("user-token", "11-7788")
    end
  end

  describe "revoke_token/2" do
    test "sends the token_type_hint X requires" do
      # Without it X answers 400 and the credential stays live, so a
      # disconnect leaves a working token behind. Found when a real
      # disconnect failed to revoke.
      Req.Test.stub(X, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert conn.request_path == "/2/oauth2/revoke"
        assert params["token"] == "some-token"
        assert params["token_type_hint"] == "access_token"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"revoked":true}))
      end)

      assert {:ok, _} = X.revoke_token("some-token")
    end
  end

  describe "post_metrics/2" do
    test "reads an authoritative impression count from X" do
      Req.Test.stub(X, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.method == "GET"
        assert conn.request_path == "/2/tweets/post-1"
        assert conn.query_params["tweet.fields"] =~ "public_metrics"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer user-token"]

        json(conn, 200, %{
          "data" => %{"public_metrics" => %{"impression_count" => 1_234}}
        })
      end)

      assert {:ok, %{views: 1_234}} = X.post_metrics("post-1", "user-token")
    end

    test "fails closed when X omits the impression count" do
      Req.Test.stub(X, fn conn -> json(conn, 200, %{"data" => %{"public_metrics" => %{}}}) end)

      assert {:error, :metrics_unavailable} = X.post_metrics("post-1", "user-token")
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
