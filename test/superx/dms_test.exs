defmodule SuperX.DMsTest do
  use SuperX.DataCase, async: false

  import ExUnit.CaptureLog
  import SuperX.Fixtures

  alias SuperX.{AI, DMs}
  alias SuperX.DMs.Message
  alias SuperX.Engage.Replier
  alias SuperX.X
  alias SuperX.XChat.Identity

  setup do
    previous = Application.get_env(:superx, X, [])
    previous_xchat_handler = Application.get_env(:superx, :xchat_stub_handler)
    Application.delete_env(:superx, :xchat_stub_handler)

    Application.put_env(
      :superx,
      X,
      Keyword.merge(previous,
        api_base: "https://api.x.com/2",
        dm_enabled: true
      )
    )

    on_exit(fn ->
      Application.put_env(:superx, X, previous)

      if previous_xchat_handler do
        Application.put_env(:superx, :xchat_stub_handler, previous_xchat_handler)
      else
        Application.delete_env(:superx, :xchat_stub_handler)
      end
    end)

    user_fixture(x_user_id: "100", scopes: ~w(tweet.read tweet.write dm.read dm.write))
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

    test "encrypts an XChat reply and never calls the legacy send endpoint", %{account: account} do
      conversation =
        dm_conversation_fixture(account, %{
          participant_x_user_id: "200",
          x_conversation_id: "100-200",
          encrypted: true
        })

      identity =
        account
        |> Identity.create_changeset(
          "stored-private-key",
          "7",
          %{"version" => "7", "public_key" => %{}}
        )
        |> Repo.insert!()
        |> Identity.registered_changeset(~U[2026-08-02 08:00:00Z])
        |> Repo.update!()

      Application.put_env(:superx, :xchat_stub_handler, fn
        :available, _params ->
          true

        :register_keys, _params ->
          flunk("a stored identity must not be replaced")

        :encrypt_message, params ->
          assert params["private_key"] == identity.private_key
          assert params["key_version"] == "7"
          assert params["conversation_id"] == "100-200"
          assert params["text"] == "Encrypted reply"
          assert params["events"] == ["key-change", "ciphertext"]

          {:ok,
           %{
             "message_id" => "xchat-message-id",
             "encoded_message_create_event" => "encrypted-body",
             "encoded_message_event_signature" => "signed-body"
           }}
      end)

      Req.Test.stub(X, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case {conn.method, conn.request_path} do
          {"GET", "/2/users/100/public_keys"} ->
            json(conn, 200, %{"data" => [public_key()]})

          {"GET", "/2/users/200/public_keys"} ->
            json(conn, 200, %{"data" => [public_key()]})

          {"GET", "/2/chat/conversations/100-200/events"} ->
            json(conn, 200, %{
              "data" => [%{"encoded_event" => "ciphertext"}],
              "meta" => %{"conversation_key_events" => ["key-change"]}
            })

          {"POST", "/2/chat/conversations/100-200/messages"} ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            body = Jason.decode!(raw)

            refute raw =~ "Encrypted reply"
            assert body["message_id"] == "xchat-message-id"
            assert body["encoded_message_create_event"] == "encrypted-body"
            assert body["encoded_message_event_signature"] == "signed-body"

            json(conn, 201, %{"data" => %{"encoded_message_event" => "accepted"}})

          other ->
            flunk("unexpected X request: #{inspect(other)}")
        end
      end)

      assert {:ok, message} = DMs.send_reply(account, conversation.id, "Encrypted reply")
      assert message.x_message_id == "xchat-message-id"
      assert message.direction == "outbound"

      stored = DMs.get_conversation(account, conversation.id)
      assert stored.encrypted
      assert stored.last_message_text == "Encrypted reply"
    end
  end

  describe "sync/1" do
    test "ingests paginated conversations idempotently and distinguishes direction", %{
      account: account
    } do
      Req.Test.stub(X, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.method == "GET"
        assert conn.request_path == "/2/dm_events"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer access-token"]
        assert conn.query_params["max_results"] == "100"
        assert conn.query_params["event_types"] == "MessageCreate"

        assert conn.query_params["dm_event.fields"] ==
                 "created_at,dm_conversation_id,event_type,id,participant_ids,sender_id,text"

        assert conn.query_params["expansions"] == "participant_ids,sender_id"
        assert conn.query_params["user.fields"] == "id,name,profile_image_url,username"

        case conn.query_params["pagination_token"] do
          nil ->
            json(conn, 200, %{
              "data" => [
                %{
                  "id" => "event-inbound",
                  "event_type" => "MessageCreate",
                  "text" => "The newer inbound message",
                  "sender_id" => "200",
                  "dm_conversation_id" => "100-200",
                  "created_at" => "2026-08-01T09:05:00.123Z"
                }
              ],
              "includes" => %{
                "users" => [
                  %{
                    "id" => "200",
                    "username" => "counterparty",
                    "name" => "Counter Party",
                    "profile_image_url" => "https://img.test/counterparty_normal.jpg"
                  }
                ]
              },
              "meta" => %{
                "result_count" => 1,
                "next_token" => "ABCDEFGHIJKLMNOP"
              }
            })

          "ABCDEFGHIJKLMNOP" ->
            json(conn, 200, %{
              "data" => [
                %{
                  "id" => "event-outbound",
                  "event_type" => "MessageCreate",
                  "text" => "The older outbound message",
                  "sender_id" => "100",
                  "dm_conversation_id" => "100-200",
                  "created_at" => "2026-08-01T09:00:00.456Z"
                }
              ],
              "meta" => %{"result_count" => 1}
            })
        end
      end)

      assert {:ok, %{conversations: 1, messages: 2, skipped: 0}} = DMs.sync(account)

      assert [conversation] = DMs.list_conversations(account)
      assert conversation.x_conversation_id == "100-200"
      assert conversation.participant_x_user_id == "200"
      assert conversation.participant_handle == "counterparty"
      assert conversation.participant_name == "Counter Party"
      assert conversation.last_message_text == "The newer inbound message"
      assert conversation.last_message_at == ~U[2026-08-01 09:05:00Z]

      stored = DMs.get_conversation(account, conversation.id)

      assert [
               %{x_message_id: "event-outbound", direction: "outbound"},
               %{x_message_id: "event-inbound", direction: "inbound"}
             ] = stored.messages

      assert {:ok, %{conversations: 1, messages: 2, skipped: 0}} = DMs.sync(account)
      assert Repo.aggregate(Message, :count) == 2
    end

    test "decrypts XChat history idempotently without exposing its private identity", %{
      account: account
    } do
      secret = "xchat-private-key-that-must-never-appear"
      calls = start_supervised!({Agent, fn -> %{generations: 0, registrations: 0} end})

      Application.put_env(:superx, :xchat_stub_handler, fn
        :available, _params ->
          true

        :register_keys, _params ->
          Agent.update(calls, &Map.update!(&1, :generations, fn count -> count + 1 end))

          {:ok,
           %{
             "private_key" => secret,
             "key_version" => "7",
             "registration" => %{
               "version" => "7",
               "generate_version" => false,
               "public_key" => %{"public_key" => "identity-public"}
             }
           }}

        :decrypt_events, params ->
          assert params["private_key"] == secret
          assert params["key_version"] == "7"
          assert params["user_id"] == "100"
          assert params["events"] == ["key-change", "cipher-inbound", "cipher-outbound"]
          assert length(params["signing_keys"]) == 2

          {:ok,
           %{
             "events" => [
               %{
                 "type" => "message",
                 "id" => "xchat-outbound",
                 "senderId" => "100",
                 "createdAtMsec" => 1_775_205_000_000,
                 "content" => %{"text" => "The older encrypted reply"}
               },
               %{
                 "type" => "message",
                 "id" => "xchat-inbound",
                 "senderId" => "200",
                 "createdAtMsec" => 1_775_205_300_000,
                 "content" => %{"text" => "The newer encrypted message"}
               }
             ],
             "errors" => %{}
           }}
      end)

      Req.Test.stub(X, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case {conn.method, conn.request_path} do
          {"GET", "/2/dm_events"} ->
            json(conn, 200, %{"meta" => %{"result_count" => 0}})

          {"POST", "/2/users/100/public_keys"} ->
            Agent.update(calls, &Map.update!(&1, :registrations, fn count -> count + 1 end))
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            refute raw =~ secret
            assert Jason.decode!(raw)["version"] == "7"
            json(conn, 200, %{"data" => public_key()})

          {"GET", "/2/chat/conversations"} ->
            assert conn.query_params["chat_conversation.fields"] ==
                     "id,participant_ids,type"

            json(conn, 200, %{
              "data" => [
                %{
                  "id" => "100-200",
                  "type" => "direct",
                  "participant_ids" => ["100", "200"]
                }
              ],
              "includes" => %{
                "users" => [
                  %{
                    "id" => "200",
                    "username" => "encrypted_friend",
                    "name" => "Encrypted Friend",
                    "profile_image_url" => "https://img.test/encrypted.jpg"
                  }
                ]
              },
              "meta" => %{"result_count" => 1}
            })

          {"GET", "/2/users/100/public_keys"} ->
            json(conn, 200, %{"data" => [public_key()]})

          {"GET", "/2/users/200/public_keys"} ->
            json(conn, 200, %{"data" => [public_key()]})

          {"GET", "/2/chat/conversations/100-200/events"} ->
            assert conn.query_params["chat_message_event.fields"] ==
                     "conversation_id,created_at_msec,encoded_event,id,sender_id"

            json(conn, 200, %{
              "data" => [
                %{"encoded_event" => "cipher-inbound"},
                %{"encoded_event" => "cipher-outbound"}
              ],
              "meta" => %{"conversation_key_events" => ["key-change"]}
            })

          other ->
            flunk("unexpected X request: #{inspect(other)}")
        end
      end)

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, %{conversations: 1, messages: 2, skipped: 0}} = DMs.sync(account)
          assert {:ok, %{conversations: 1, messages: 2, skipped: 0}} = DMs.sync(account)
        end)

      refute log =~ secret
      assert Agent.get(calls, & &1) == %{generations: 1, registrations: 1}
      assert Repo.aggregate(Message, :count) == 2

      assert [conversation] = DMs.list_conversations(account)
      assert conversation.encrypted
      assert conversation.participant_x_user_id == "200"
      assert conversation.participant_handle == "encrypted_friend"
      assert conversation.last_message_text == "The newer encrypted message"

      assert [
               %{x_message_id: "xchat-outbound", direction: "outbound"},
               %{x_message_id: "xchat-inbound", direction: "inbound"}
             ] = DMs.get_conversation(account, conversation.id).messages

      identity = Repo.get_by!(Identity, x_account_id: account.id)
      assert identity.private_key == secret
      refute inspect(identity) =~ secret

      %{rows: [[ciphertext]]} =
        Repo.query!("SELECT private_key FROM xchat_identities WHERE id = $1", [
          Ecto.UUID.dump!(identity.id)
        ])

      refute ciphertext == secret
    end

    test "marks an older OAuth grant for reconnection without calling X", %{account: account} do
      account =
        account |> Ecto.Changeset.change(scopes: ~w(tweet.read tweet.write)) |> Repo.update!()

      Req.Test.stub(X, fn _conn ->
        flunk("a known missing scope must not make an external read")
      end)

      assert {:error, :reauth_required} = DMs.sync(account)

      account = Repo.reload(account)
      assert account.reauth_needed
      assert account.reauth_reason =~ "DM access was not granted"
      assert account.access_token == nil
      assert DMs.availability(account) == :reauthorize
    end

    test "keeps an app permission-tier 403 distinct from account reconnection", %{
      account: account
    } do
      Req.Test.stub(X, fn conn ->
        json(conn, 403, %{"title" => "Client Forbidden"})
      end)

      assert {:error, {:dm_permission_tier_required, %{"title" => "Client Forbidden"}}} =
               DMs.sync(account)

      refute Repo.reload(account).reauth_needed
    end
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

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp public_key do
    %{
      "public_key_version" => "7",
      "public_key" => "identity-public",
      "signing_public_key" => "signing-public",
      "identity_public_key_signature" => "binding-signature"
    }
  end
end
