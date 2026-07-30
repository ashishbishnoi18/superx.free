defmodule SuperX.AITest do
  @moduledoc """
  Pins the two assumptions that reasoning models broke, plus the provider
  seam — all three were silent failures rather than crashes.
  """

  use ExUnit.Case, async: true

  alias SuperX.AI

  setup do
    previous = Application.get_env(:superx, AI, [])

    Application.put_env(
      :superx,
      AI,
      Keyword.merge(previous,
        api_key: "test-key",
        provider: "deepseek",
        base_url: "https://api.deepseek.com/anthropic",
        writer_model: "deepseek-v4-pro",
        utility_model: "deepseek-v4-flash"
      )
    )

    on_exit(fn -> Application.put_env(:superx, AI, previous) end)
    :ok
  end

  defp stub(fun), do: Req.Test.stub(AI, fun)

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp read_body(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(raw), conn}
  end

  describe "provider routing" do
    test "sends to the configured base URL with x-api-key" do
      stub(fn conn ->
        assert conn.host == "api.deepseek.com"
        assert conn.request_path == "/anthropic/v1/messages"
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]
        json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}]})
      end)

      assert {:ok, "ok"} = AI.complete("hi")
    end

    test "reports the provider in use" do
      assert AI.provider() == "deepseek"
      assert AI.writer_model() == "deepseek-v4-pro"
    end
  end

  describe "reasoning-model behaviour" do
    test "structured output asks for any tool, never a named one" do
      # Naming the tool is rejected while thinking is on. With exactly one
      # tool defined, `any` means the same thing and works in both modes.
      stub(fn conn ->
        {body, conn} = read_body(conn)
        assert body["tool_choice"] == %{"type" => "any"}
        assert length(body["tools"]) == 1

        json(conn, %{
          "content" => [%{"type" => "tool_use", "name" => "respond", "input" => %{"colour" => "blue"}}]
        })
      end)

      schema = %{type: "object", properties: %{colour: %{type: "string"}}}
      assert {:ok, %{"colour" => "blue"}} = AI.structured("pick", schema)
    end

    test "ignores thinking blocks when extracting text" do
      stub(fn conn ->
        json(conn, %{
          "content" => [
            %{"type" => "thinking", "thinking" => "hmm, let me consider"},
            %{"type" => "text", "text" => "the answer"}
          ]
        })
      end)

      assert {:ok, "the answer"} = AI.complete("hi")
    end

    test "a response with only thinking is an error, not an empty string" do
      # A tight max_tokens gets spent on thinking, returning 200 with no
      # text. Returning "" here surfaced as a blank draft.
      stub(fn conn ->
        json(conn, %{
          "content" => [%{"type" => "thinking", "thinking" => "..."}],
          "stop_reason" => "max_tokens"
        })
      end)

      assert {:error, {:empty_response, "max_tokens"}} = AI.complete("hi", max_tokens: 10)
    end

    test "thinking is disabled only when the caller asks" do
      stub(fn conn ->
        {body, conn} = read_body(conn)
        assert body["thinking"] == %{"type" => "disabled"}
        json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}]})
      end)

      assert {:ok, "ok"} = AI.complete("hi", thinking: false)

      stub(fn conn ->
        {body, conn} = read_body(conn)
        refute Map.has_key?(body, "thinking")
        json(conn, %{"content" => [%{"type" => "text", "text" => "ok"}]})
      end)

      assert {:ok, "ok"} = AI.complete("hi")
    end
  end

  describe "errors" do
    test "a tool call that never arrives is an error, not a silent nil" do
      stub(fn conn -> json(conn, %{"content" => [%{"type" => "text", "text" => "I'd rather chat"}]}) end)

      assert {:error, {:no_tool_use, _}} = AI.structured("pick", %{type: "object"})
    end

    test "refuses to call without a key" do
      previous = Application.get_env(:superx, AI, [])
      Application.put_env(:superx, AI, Keyword.put(previous, :api_key, nil))
      on_exit(fn -> Application.put_env(:superx, AI, previous) end)

      refute AI.configured?()
      assert {:error, :not_configured} = AI.complete("hi")
    end
  end
end
