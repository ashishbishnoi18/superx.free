defmodule SuperX.AskTest do
  @moduledoc """
  The loop spends credits and can call tools that write, so the guarantees
  worth pinning are: it stops, it charges once, it refunds on failure, and
  it records what it actually did.
  """

  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.{Ask, Articles, Billing, Content, Engage, Signals}
  alias SuperX.Ask.Tools

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

      reloaded = Ask.get_chat(user, account, chat.id)
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

    test "refunds when every requested tool fails", %{
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

      before = Billing.credit_balance(user)

      assert {:error, :all_tools_failed} = Ask.ask(user, account, chat, "what's queued")
      assert Billing.credit_balance(user) == before
    end

    test "refunds after the round ceiling rather than charging for no answer", %{
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

      before = Billing.credit_balance(user)

      assert {:error, :tool_round_limit} = Ask.ask(user, account, chat, "loop forever")
      assert Billing.credit_balance(user) == before

      # Bounded, not unbounded — the exact number matters less than that
      # there is one.
      assert Agent.get(calls, & &1) <= 6
    end

    test "the advertised turn cost includes a draft tool's nested generation", %{
      user: user,
      account: account,
      chat: chat
    } do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      stub(fn conn ->
        case Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) do
          1 ->
            json(conn, tool_reply("draft_post", %{"topic" => "durable software"}))

          2 ->
            json(conn, %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "draft_1",
                  "name" => "respond",
                  "input" => %{"segments" => ["Software should survive its first plan."]}
                }
              ]
            })

          _ ->
            json(conn, text_reply("I wrote that and put it on Ready to Post."))
        end
      end)

      before = Billing.credit_balance(user)

      assert {:ok, message} = Ask.ask(user, account, chat, "Draft a post about durability")
      assert message.content =~ "Ready to Post"
      assert Billing.credit_balance(user) == before - Ask.credit_cost()
    end
  end

  describe "billing" do
    test "refunds when the model never answers", %{user: user, account: account, chat: chat} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 500, "upstream is down") end)

      before = Billing.credit_balance(user)

      assert {:error, _reason} = Ask.ask(user, account, chat, "how am I doing")
      assert Billing.credit_balance(user) == before
    end

    test "refunds when the claimed turn cannot record the user's message", %{
      user: user,
      account: account
    } do
      invalid_chat = %SuperX.Ask.Chat{
        user_id: user.id,
        x_account_id: account.id
      }

      before = Billing.credit_balance(user)

      assert {:error, %Ecto.Changeset{}} =
               Ask.ask(user, account, invalid_chat, "This cannot be stored")

      assert Billing.credit_balance(user) == before
    end

    test "refuses when out of credits", %{user: user, account: account, chat: chat} do
      limit = Billing.Plan.limit("free", :credits_month)
      {:ok, _} = Billing.claim(user, "credits_month", limit)

      assert {:error, :quota_exceeded, _} = Ask.ask(user, account, chat, "how am I doing")
    end
  end

  describe "chats" do
    test "are scoped to their owner and selected account", %{
      user: user,
      account: account,
      chat: chat
    } do
      %{user: other, account: other_account} = user_fixture()
      assert Ask.get_chat(other, other_account, chat.id) == nil

      {:ok, _subscription} =
        Billing.upsert_subscription(user, %{tier: "pro", status: "active"})

      {:ok, second_account} =
        SuperX.Accounts.Connect.attach(
          user,
          %{
            x_user_id: "second-#{System.unique_integer([:positive])}",
            handle: "second_account"
          },
          %{access_token: "second-token"}
        )

      {:ok, second_chat} = Ask.create_chat(user, second_account, "Second account chat")

      assert Enum.map(Ask.list_chats(user, account), & &1.id) == [chat.id]
      assert Enum.map(Ask.list_chats(user, second_account), & &1.id) == [second_chat.id]
      assert Ask.get_chat(user, second_account, chat.id) == nil
      assert {:error, :not_found} = Ask.delete_chat(user, second_account, chat.id)

      before = Billing.credit_balance(user)
      assert {:error, :chat_account_mismatch} = Ask.ask(user, second_account, chat, "continue")
      assert Billing.credit_balance(user) == before
    end

    test "title is derived from the opening question" do
      title = Ask.title_from("How is my account doing this month and what should I post about")
      assert title == "How is my account doing this month"
    end
  end

  describe "get_shelf" do
    test "reads the shelf rather than inferring it from the queue", %{
      user: user,
      account: account
    } do
      # Without this tool the model answered questions about drafts from
      # get_queue, which only sees posts — and confidently reported an
      # empty shelf while eighteen drafts were sitting on it.
      {:ok, _generation} =
        Content.create_generation(%{
          user_id: user.id,
          x_account_id: account.id,
          segments: [%{"text" => "a draft waiting for review", "media_ids" => []}],
          kind: "for_you",
          source_likes: 4200
        })

      ctx = %{user: user, account: account}
      {:ok, body, summary} = Tools.run("get_shelf", %{}, ctx)

      assert body =~ "a draft waiting for review"
      assert body =~ "4200 likes"
      # The count has to be the real total, not the page size.
      assert body =~ "1 draft(s) on the shelf"
      assert summary =~ "shelf"
    end

    test "says so plainly when the shelf is empty", %{user: user, account: account} do
      assert {:ok, "The shelf is empty.", _} =
               Tools.run("get_shelf", %{}, %{user: user, account: account})
    end
  end

  describe "account data tools" do
    test "reads long-form Articles instead of falling back to post drafts", %{
      user: user,
      account: account
    } do
      {:ok, _article} =
        Articles.create_article(user, account, %{
          title: "The long argument",
          body: "This belongs in the long-form editor, not the post queue."
        })

      assert {:ok, body, _summary} =
               Tools.run("get_articles", %{"status" => "draft"}, %{
                 user: user,
                 account: account
               })

      assert body =~ "The long argument"
      assert body =~ "long-form editor"
    end

    test "filters contacts by the relationship stage the user asked for", %{
      user: user,
      account: account
    } do
      assert {2, _} =
               Signals.upsert_leads([
                 %{
                   x_account_id: account.id,
                   handle: "new_high_score",
                   status: "new",
                   score: 99
                 },
                 %{
                   x_account_id: account.id,
                   handle: "already_contacted",
                   status: "contacted",
                   score: 10
                 }
               ])

      contacted = account |> Signals.list_leads(status: "contacted") |> hd()
      {:ok, _contacted} = Signals.update_lead(contacted, %{notes: "Asked to follow up next week"})

      assert {:ok, body, _summary} =
               Tools.run("get_leads", %{"status" => "contacted"}, %{
                 user: user,
                 account: account
               })

      assert body =~ "@already_contacted [contacted]"
      assert body =~ "follow up next week"
      refute body =~ "new_high_score"
    end

    test "can distinguish topic-feed items from higher-priority mentions", %{
      user: user,
      account: account
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {2, _} =
               Engage.upsert_many([
                 %{
                   x_account_id: account.id,
                   kind: "mention",
                   x_post_id: "mention-1",
                   author_handle: "mention_author",
                   text: "A high-priority mention",
                   posted_at: now,
                   priority: 100
                 },
                 %{
                   x_account_id: account.id,
                   kind: "feed",
                   x_post_id: "feed-1",
                   author_handle: "feed_author",
                   text: "A topic-feed post",
                   posted_at: now,
                   priority: 1
                 }
               ])

      assert {:ok, body, _summary} =
               Tools.run("get_engagements", %{"kind" => "feed"}, %{
                 user: user,
                 account: account
               })

      assert body =~ "A topic-feed post"
      refute body =~ "high-priority mention"
    end

    test "reports configured topic feeds even before they have fetched", %{
      user: user,
      account: account
    } do
      {:ok, _feed} = Engage.create_feed(account, %{query: "phoenix liveview", ranking: "newest"})

      assert {:ok, body, _summary} =
               Tools.run("get_feeds", %{}, %{user: user, account: account})

      assert body =~ "phoenix liveview"
      assert body =~ "newest"
      assert body =~ "not fetched yet"
    end
  end
end
