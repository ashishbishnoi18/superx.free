defmodule SuperX.DMsTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.{AI, DMs}
  alias SuperX.DMs.Message
  alias SuperX.Engage.Replier
  alias SuperX.X

  setup do
    previous = Application.get_env(:superx, X, [])

    Application.put_env(
      :superx,
      X,
      Keyword.merge(previous,
        api_base: "https://api.x.com/2",
        dm_enabled: true
      )
    )

    on_exit(fn -> Application.put_env(:superx, X, previous) end)

    user_fixture(scopes: ~w(tweet.read tweet.write dm.read dm.write))
  end

  describe "account boundaries" do
    test "the same participant remains separate for each connected account", %{account: account} do
      %{account: other_account} =
        user_fixture(scopes: ~w(tweet.read tweet.write dm.read dm.write))

      assert {:ok, first} =
               DMs.upsert_conversation(account, %{
                 participant_x_user_id: "7788",
                 participant_handle: "first_name"
               })

      assert {:ok, second} =
               DMs.upsert_conversation(other_account, %{
                 participant_x_user_id: "7788",
                 participant_handle: "second_name"
               })

      assert first.id != second.id
      assert [%{participant_handle: "first_name"}] = DMs.list_conversations(account)
      assert [%{participant_handle: "second_name"}] = DMs.list_conversations(other_account)
    end

    test "refuses another account's conversation before calling X", %{account: account} do
      %{account: other_account} =
        user_fixture(scopes: ~w(tweet.read tweet.write dm.read dm.write))

      conversation = dm_conversation_fixture(account)

      Req.Test.stub(X, fn _conn ->
        flunk("an account boundary failure must not make an external send")
      end)

      assert {:error, :not_found} =
               DMs.send_reply(other_account, conversation.id, "This must not leave the app")

      assert Repo.aggregate(Message, :count) == 0
    end
  end

  describe "send_reply/3" do
    test "records the accepted event and refreshes the inbox preview", %{account: account} do
      conversation =
        dm_conversation_fixture(account, %{
          participant_x_user_id: "7788",
          last_message_text: "Before"
        })

      Req.Test.stub(X, fn conn ->
        response = %{
          "data" => %{
            "dm_conversation_id" => "#{account.x_user_id}-7788",
            "dm_event_id" => "sent-event"
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(201, Jason.encode!(response))
      end)

      assert {:ok, message} = DMs.send_reply(account, conversation.id, "After")
      assert message.direction == "outbound"
      assert message.sender_x_user_id == account.x_user_id

      stored = DMs.get_conversation(account, conversation.id)
      assert stored.x_conversation_id == "#{account.x_user_id}-7788"
      assert stored.last_message_text == "After"
      assert [%{x_message_id: "sent-event", text: "After"}] = stored.messages
    end

    test "an empty message never reaches X", %{account: account} do
      conversation = dm_conversation_fixture(account)

      Req.Test.stub(X, fn _conn -> flunk("invalid input must not make an external send") end)

      assert {:error, :empty_message} = DMs.send_reply(account, conversation.id, "   ")
      assert Repo.aggregate(Message, :count) == 0
    end

    test "the feature flag and stored scopes both gate the external call", %{account: account} do
      conversation = dm_conversation_fixture(account)
      Req.Test.stub(X, fn _conn -> flunk("an unavailable feature must not call X") end)

      configure_dms(false)
      assert {:error, :disabled} = DMs.send_reply(account, conversation.id, "Not yet")

      configure_dms(true)
      account = %{account | scopes: ~w(tweet.read tweet.write)}
      assert {:error, :reauthorize} = DMs.send_reply(account, conversation.id, "Still not yet")
      assert Repo.aggregate(Message, :count) == 0
    end
  end

  test "sync stops at the documented provider seam", %{account: account} do
    assert {:error, :dm_read_unavailable} = DMs.sync(account)
  end

  test "drafts from the private thread with the shared voice writer", %{
    user: user,
    account: account
  } do
    previous = Application.get_env(:superx, AI, [])

    Application.put_env(
      :superx,
      AI,
      Keyword.merge(previous,
        api_key: "test-key",
        base_url: "https://api.anthropic.test",
        writer_model: "writer-test"
      )
    )

    on_exit(fn -> Application.put_env(:superx, AI, previous) end)

    Req.Test.stub(AI, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      prompt = Jason.decode!(raw) |> get_in(["messages", Access.at(0), "content"])

      assert prompt =~ "private X conversation"
      assert prompt =~ "Can you send the details?"
      assert prompt =~ "I will put them together."

      response = %{
        "content" => [
          %{
            "type" => "tool_use",
            "name" => "respond",
            "input" => %{"reply" => "Yes. I will send the short version today."}
          }
        ]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end)

    messages = [
      %Message{direction: "outbound", text: "I will put them together."},
      %Message{direction: "inbound", text: "Can you send the details?"}
    ]

    assert {:ok, "Yes. I will send the short version today."} =
             Replier.draft_direct_message(user, account, "someone", messages)
  end

  test "does not spend a draft when the latest message is the user's own", %{
    user: user,
    account: account
  } do
    messages = [%Message{direction: "outbound", text: "I sent the details."}]

    assert {:error, :nothing_to_reply_to} =
             Replier.draft_direct_message(user, account, "someone", messages)
  end

  defp configure_dms(enabled) do
    config = Application.get_env(:superx, X, [])
    Application.put_env(:superx, X, Keyword.put(config, :dm_enabled, enabled))
  end
end
