defmodule SuperXWeb.MCPController do
  @moduledoc """
  The stateless Streamable HTTP boundary for the tools Ask already uses.

  MCP owns protocol negotiation and JSON-RPC framing here; authority and
  side effects remain in the bearer credential and the shared tool registry,
  so another transport cannot acquire a broader account view or a publish
  path by accident.
  """

  use SuperXWeb, :controller

  alias SuperX.Accounts.XAccount
  alias SuperX.Ask.Tools

  @protocol_versions ~w(2025-11-25 2025-06-18 2025-03-26)
  @latest_protocol hd(@protocol_versions)

  plug :validate_origin

  def handle(conn, request) do
    with :ok <- validate_protocol_header(conn) do
      handle_message(conn, request)
    else
      {:error, message} -> protocol_error(conn, nil, -32600, message, :bad_request)
    end
  end

  # This server has nothing to initiate between calls. A 405 is the MCP
  # signal that clients should keep using request-bound POST responses.
  def stream(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(:method_not_allowed, "")
  end

  def close(conn, _params) do
    conn
    |> put_resp_header("allow", "GET, POST")
    |> send_resp(:method_not_allowed, "")
  end

  defp handle_message(
         conn,
         %{"jsonrpc" => "2.0", "id" => id, "method" => method} = request
       )
       when (is_binary(id) or is_integer(id)) and is_binary(method) do
    dispatch(conn, id, method, Map.get(request, "params", %{}))
  end

  defp handle_message(conn, %{"jsonrpc" => "2.0", "method" => method})
       when is_binary(method) do
    send_resp(conn, :accepted, "")
  end

  defp handle_message(conn, %{"jsonrpc" => "2.0", "id" => id} = response)
       when is_binary(id) or is_integer(id) do
    if Map.has_key?(response, "result") or Map.has_key?(response, "error") do
      send_resp(conn, :accepted, "")
    else
      protocol_error(conn, id, -32600, "Invalid Request")
    end
  end

  defp handle_message(conn, request) do
    id = if is_map(request), do: Map.get(request, "id"), else: nil
    protocol_error(conn, id, -32600, "Invalid Request")
  end

  defp dispatch(conn, id, "initialize", %{
         "protocolVersion" => requested,
         "capabilities" => capabilities,
         "clientInfo" => client_info
       })
       when is_binary(requested) and is_map(capabilities) and is_map(client_info) do
    version = if requested in @protocol_versions, do: requested, else: @latest_protocol

    result(conn, id, %{
      protocolVersion: version,
      capabilities: %{tools: %{listChanged: false}},
      serverInfo: %{name: "superx", title: "SuperX", version: server_version()},
      instructions:
        "Tools act on the X account selected in SuperX. They may create Ready to Post drafts, but never schedule or publish."
    })
  end

  defp dispatch(conn, id, "initialize", _params) do
    protocol_error(conn, id, -32602, "Invalid initialize parameters")
  end

  defp dispatch(conn, id, "ping", params) when is_map(params), do: result(conn, id, %{})

  defp dispatch(conn, id, "tools/list", params) when is_map(params) do
    tools = Enum.map(Tools.definitions(), &mcp_tool/1)
    result(conn, id, %{tools: tools})
  end

  defp dispatch(
         conn,
         id,
         "tools/call",
         %{"name" => name} = params
       )
       when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})

    if is_map(arguments) do
      call_tool(conn, id, name, arguments)
    else
      protocol_error(conn, id, -32602, "Invalid tools/call parameters")
    end
  end

  defp dispatch(conn, id, "tools/call", _params) do
    protocol_error(conn, id, -32602, "Invalid tools/call parameters")
  end

  defp dispatch(conn, id, _method, _params) do
    protocol_error(conn, id, -32601, "Method not found")
  end

  defp call_tool(%{assigns: %{current_x_account: %XAccount{}}} = conn, id, name, arguments) do
    context = %{
      user: conn.assigns.current_user,
      account: conn.assigns.current_x_account
    }

    case Tools.run(name, arguments, context) do
      {:ok, text, _summary} -> tool_result(conn, id, text, false)
      {:error, :unknown_tool, message} -> protocol_error(conn, id, -32602, message)
      {:error, message} -> tool_result(conn, id, message, true)
    end
  end

  defp call_tool(conn, id, _name, _arguments) do
    tool_result(conn, id, "Connect an X account before calling tools.", true)
  end

  defp mcp_tool(definition) do
    %{
      name: definition.name,
      description: definition.description,
      inputSchema: definition.input_schema
    }
  end

  defp tool_result(conn, id, text, error?) do
    result(conn, id, %{
      content: [%{type: "text", text: text}],
      isError: error?
    })
  end

  defp result(conn, id, value) do
    json(conn, %{jsonrpc: "2.0", id: id, result: value})
  end

  defp protocol_error(conn, id, code, message, status \\ :ok) do
    conn
    |> put_status(status)
    |> json(%{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
  end

  defp validate_protocol_header(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        :ok

      [version] when version in @protocol_versions ->
        :ok

      [_version] ->
        {:error, "Unsupported MCP-Protocol-Version"}

      _multiple ->
        {:error, "Invalid MCP-Protocol-Version header"}
    end
  end

  defp validate_origin(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin] ->
        if same_origin?(conn, origin) do
          conn
        else
          conn
          |> protocol_error(nil, -32600, "Invalid Origin", :forbidden)
          |> halt()
        end

      _multiple ->
        conn
        |> protocol_error(nil, -32600, "Invalid Origin", :forbidden)
        |> halt()
    end
  end

  defp same_origin?(conn, origin) do
    with {:ok, uri} <- URI.new(origin),
         true <- is_binary(uri.host),
         true <- is_nil(uri.userinfo),
         true <- is_nil(uri.query),
         true <- is_nil(uri.fragment) do
      String.downcase(uri.host) == String.downcase(conn.host) and
        uri.scheme == Atom.to_string(conn.scheme) and uri.port == conn.port
    else
      _ -> false
    end
  end

  defp server_version do
    case Application.spec(:superx, :vsn) do
      nil -> "development"
      version -> to_string(version)
    end
  end
end
