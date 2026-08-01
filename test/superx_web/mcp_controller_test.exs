defmodule SuperXWeb.MCPControllerTest do
  use SuperXWeb.ConnCase, async: true

  import SuperX.Fixtures

  alias SuperX.{Accounts, Billing, Content}

  @protocol_version "2025-11-25"

  setup do
    %{user: user, account: account} = user_fixture()
    {:ok, _api_token, plaintext} = Accounts.create_api_token(user, %{"name" => "MCP client"})

    %{user: user, account: account, plaintext: plaintext}
  end

  test "initialises with the tools capability", %{conn: conn, plaintext: plaintext} do
    body =
      conn
      |> mcp(plaintext, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => @protocol_version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      })
      |> json_response(200)

    assert body["id"] == 1
    assert body["result"]["protocolVersion"] == @protocol_version
    assert body["result"]["capabilities"] == %{"tools" => %{"listChanged" => false}}
    assert body["result"]["serverInfo"]["name"] == "superx"
  end

  test "lists the shared Ask tools with MCP input schemas", %{conn: conn, plaintext: plaintext} do
    body =
      conn
      |> mcp(plaintext, request(2, "tools/list", %{}))
      |> json_response(200)

    tools = body["result"]["tools"]

    assert Enum.map(tools, & &1["name"]) == Enum.map(SuperX.Ask.Tools.definitions(), & &1.name)

    assert %{
             "description" => description,
             "inputSchema" => %{
               "type" => "object",
               "required" => ["topic"]
             }
           } = Enum.find(tools, &(&1["name"] == "draft_post"))

    assert description =~ "does not publish"
    refute Map.has_key?(hd(tools), "input_schema")
  end

  test "calls a read tool against the credential's selected account", %{
    conn: conn,
    user: user,
    account: account,
    plaintext: plaintext
  } do
    scheduled_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

    {:ok, _post} =
      Content.create_post(user, account, %{
        status: "scheduled",
        scheduled_at: scheduled_at,
        segments: [%{"text" => "Visible to this credential"}]
      })

    %{user: other_user, account: other_account} = user_fixture()

    {:ok, _other_post} =
      Content.create_post(other_user, other_account, %{
        status: "scheduled",
        scheduled_at: scheduled_at,
        segments: [%{"text" => "Must not cross accounts"}]
      })

    body =
      conn
      |> mcp(
        plaintext,
        request(3, "tools/call", %{
          "name" => "get_queue",
          "arguments" => %{"status" => "scheduled"}
        })
      )
      |> json_response(200)

    assert body["result"]["isError"] == false
    assert [%{"type" => "text", "text" => text}] = body["result"]["content"]
    assert text =~ "Visible to this credential"
    refute text =~ "Must not cross accounts"
  end

  test "returns an unknown tool as a JSON-RPC error", %{conn: conn, plaintext: plaintext} do
    body =
      conn
      |> mcp(
        plaintext,
        request(4, "tools/call", %{"name" => "publish_post", "arguments" => %{}})
      )
      |> json_response(200)

    assert body["error"] == %{"code" => -32602, "message" => "Unknown tool: publish_post"}
    refute Map.has_key?(body, "result")
  end

  test "returns execution failures as tool errors", %{conn: conn, plaintext: plaintext} do
    body =
      conn
      |> mcp(
        plaintext,
        request(5, "tools/call", %{
          "name" => "get_queue",
          "arguments" => %{"status" => 123}
        })
      )
      |> json_response(200)

    assert body["result"]["isError"] == true
    assert [%{"text" => message, "type" => "text"}] = body["result"]["content"]
    assert message =~ "status must be a string"
  end

  test "rejects an empty paid-tool input before spending credits", %{
    conn: conn,
    user: user,
    plaintext: plaintext
  } do
    before = Billing.credit_balance(user)

    body =
      conn
      |> mcp(
        plaintext,
        request(6, "tools/call", %{
          "name" => "draft_post",
          "arguments" => %{"topic" => ""}
        })
      )
      |> json_response(200)

    assert body["result"]["isError"] == true
    assert [%{"text" => message}] = body["result"]["content"]
    assert message =~ "topic must be at least 1 character"
    assert Billing.credit_balance(user) == before
  end

  test "rejects unsupported methods with a JSON-RPC error", %{conn: conn, plaintext: plaintext} do
    body =
      conn
      |> mcp(plaintext, request(7, "posts/publish", %{}))
      |> json_response(200)

    assert body["error"] == %{"code" => -32601, "message" => "Method not found"}
  end

  test "accepts the initialized notification without a response body", %{
    conn: conn,
    plaintext: plaintext
  } do
    conn =
      mcp(conn, plaintext, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

    assert response(conn, 202) == ""
  end

  test "requires a bearer credential", %{conn: conn} do
    conn =
      post(conn, ~p"/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      })

    assert %{"error" => _message} = json_response(conn, 401)
  end

  test "declines a server event stream with the protocol's 405 signal", %{
    conn: conn,
    plaintext: plaintext
  } do
    conn =
      conn
      |> authorise(plaintext)
      |> put_req_header("accept", "text/event-stream")
      |> get(~p"/mcp")

    assert response(conn, 405) == ""
    assert get_resp_header(conn, "allow") == ["POST"]
  end

  defp request(id, method, params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp mcp(conn, plaintext, body) do
    conn
    |> authorise(plaintext)
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @protocol_version)
    |> post(~p"/mcp", body)
  end

  defp authorise(conn, plaintext) do
    put_req_header(conn, "authorization", "Bearer #{plaintext}")
  end

  test "is rate limited by the same plan limit as the REST API", %{
    conn: conn,
    user: user,
    plaintext: plaintext
  } do
    # MCP shares the :authenticated_api pipeline, so the limiter covers it
    # without a second implementation. That is an integration fact rather
    # than something either module asserts on its own, so it is pinned
    # here — an unlimited agent transport is how one token becomes an
    # outage.
    limit = user |> SuperX.Billing.tier() |> SuperX.Billing.Plan.limit(:api_requests_minute)

    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list",
      "params" => %{}
    }

    responses =
      for _ <- 1..(limit + 1) do
        build_conn()
        |> put_req_header("authorization", "Bearer " <> plaintext)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/mcp", body)
      end

    assert Enum.any?(responses, &(&1.status == 429))
    assert conn
  end
end
