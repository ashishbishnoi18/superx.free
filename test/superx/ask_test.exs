defmodule SuperX.AskTest do
  @moduledoc """
  The loop spends credits and can call tools that write, so the guarantees
  worth pinning are: it stops, it charges once, it refunds on failure, and
  it records what it actually did.
  """

  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.{Ask, Billing}

  setup do
    previous = Application.get_env(:superx, SuperX.AI, [])

    Application.put_env(
      :superx,
      SuperX.AI,
      Keyword.merge(previous, api_key: "test-key", writer_model: "test-model")
    )

    on_exit(fn -> Application.put_env(:superx, SuperX.AI, previous) end)

    %{user: user, account: account} = user_fixture()
    {:ok, chat} = Ask.create_chat(user, account, "test")

    %{user: user, account: account, chat: chat}
  end

  defp stub(fun), do: Req.Test.stub(SuperX.AI, fun)

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp text_reply(text) do
    %{"content" => [%{"type" => "text", "text" => text}], "stop_reason" => "end_turn"}
  end

  defp tool_reply(name, input) do
    %{
      "content" => [%{"type" => "tool_use", "id" => "tu_1", "name" => name, "input" => input}],
      "stop_reason" => "tool_use"
    }
  end

  describe "a plain turn" do
    test "records both messages and charges once", %{user: user, account: account, chat: chat} do
      stub(fn conn -> json(conn, text_reply("Followers are flat.")) end)

      before = Billing.credit_balance(user)

      assert {:ok, message} = Ask.ask(user, account, chat, "How am I doing?")
      assert message.role == "assistant"
      assert message.content == "Followers are flat."

      assert Billing.credit_balance(user) == before - Ask.credit_cost()

      reloaded = Ask.get_chat(user, chat.id)
      assert Enum.map(reloaded.messages, & &1.role) == ["user", "assistant"]
    end

    test "strips markdown the UI would render literally", %{
      user: user,
      account: account,
      chat: chat
    } do
      stub(fn conn ->
        json(conn, text_reply("## Health\n\n**Followers** are up.\n\n- one\n- two"))
      end)

      assert {:ok, message} = Ask.ask(user, account, chat, "how am I doing")

      refute message.content =~ "**"
      refute message.content =~ "##"
      assert message.content =~ "Followers are up."
    end
  end

  describe "tool use" do
    test "runs the tool, feeds the result back, and records what it did", %{
      user: user,
      account: account,
      chat: chat
    } do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      stub(fn conn ->
        case Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) do
          1 -> json(conn, tool_reply("get_analytics", %{"days" => 30}))
          _ -> json(conn, text_reply("You're at 100 followers."))
        end
      end)

      assert {:ok, message} = Ask.ask(user, account, chat, "how am I doing")

      assert message.content == "You're at 100 followers."
      assert [%{"summary" => "Read 30-day analytics"}] = message.tool_calls
      assert Agent.get(calls, & &1) == 2
    end

    test "a crashing tool does not take the turn down", %{
      user: user,
      account: account,
      chat: chat
    } do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      stub(fn conn ->
        case Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) do
          # An input the tool cannot handle.
          1 -> json(conn, tool_reply("get_queue", %{"status" => 12345}))
          _ -> json(conn, text_reply("I couldn't read the queue."))
        end
      end)

      assert {:ok, message} = Ask.ask(user, account, chat, "what's queued")
      assert message.content =~ "couldn't read"
    end

    test "stops after the round ceiling rather than looping forever", %{
      user: user,
      account: account,
      chat: chat
    } do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      # A model that only ever wants to call tools.
      stub(fn conn ->
        Agent.update(calls, &(&1 + 1))
        json(conn, tool_reply("get_analytics", %{}))
      end)

      assert {:ok, message} = Ask.ask(user, account, chat, "loop forever")
      assert message.content =~ "couldn't finish"

      # Bounded, not unbounded — the exact number matters less than that
      # there is one.
      assert Agent.get(calls, & &1) <= 6
    end
  end

  describe "billing" do
    test "refunds when the model never answers", %{user: user, account: account, chat: chat} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, "upstream is down") end)

      before = Billing.credit_balance(user)

      assert {:error, _reason} = Ask.ask(user, account, chat, "how am I doing")
      assert Billing.credit_balance(user) == before
    end

    test "refuses when out of credits", %{user: user, account: account, chat: chat} do
      limit = Billing.Plan.limit("free", :credits_month)
      {:ok, _} = Billing.claim(user, "credits_month", limit)

      assert {:error, :quota_exceeded, _} = Ask.ask(user, account, chat, "how am I doing")
    end
  end

  describe "chats" do
    test "are scoped to their owner", %{chat: chat} do
      %{user: other} = user_fixture()
      assert Ask.get_chat(other, chat.id) == nil
    end

    test "title is derived from the opening question" do
      title = Ask.title_from("How is my account doing this month and what should I post about")
      assert title == "How is my account doing this month"
    end
  end
end
