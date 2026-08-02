defmodule SuperX.Engage.ReplierTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.{AI, Billing, Content, Engage}
  alias SuperX.Engage.Replier

  setup do
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

    user_fixture()
  end

  test "applies perceptible Engage reply preferences", %{user: user, account: account} do
    {:ok, profile} = Content.get_or_create_voice_profile(account)

    {:ok, _profile} =
      Content.update_voice_profile(profile, %{
        reply_length: "long",
        reply_question_policy: "ask"
      })

    Req.Test.stub(AI, fn conn ->
      prompt = request_prompt(conn)
      assert prompt =~ "two or three sentences"
      assert prompt =~ "160–260 characters"
      assert prompt =~ "End with one relevant question"
      reply(conn, "Ownership made the difference. Which boundary changed first?")
    end)

    engagement = engagement_fixture(account)

    assert {:ok, draft} = Replier.draft(user, account, engagement)
    assert draft.text == "Ownership made the difference. Which boundary changed first?"
  end

  test "unset preferences retain the current brief behaviour", %{user: user, account: account} do
    Req.Test.stub(AI, fn conn ->
      prompt = request_prompt(conn)
      assert prompt =~ "Most good replies are under 120 characters."
      refute prompt =~ "End with one relevant question"
      refute prompt =~ "Do not ask a question"
      reply(conn, "That trade-off is the part people miss.")
    end)

    assert {:ok, draft} = Replier.draft(user, account, engagement_fixture(account))
    assert draft.text == "That trade-off is the part people miss."
  end

  test "returns the daily reply allowance when generated text cannot be saved", %{
    user: user,
    account: account
  } do
    Req.Test.stub(AI, fn conn -> reply(conn, "") end)

    assert {:error, changeset} = Replier.draft(user, account, engagement_fixture(account))
    assert "can't be blank" in errors_on(changeset).text
    assert Billing.get_quota(user, "replies_day").used == 0
  end

  defp engagement_fixture(account) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, _} =
      Engage.upsert_many([
        %{
          x_account_id: account.id,
          kind: "mention",
          x_post_id: "reply-#{System.unique_integer([:positive])}",
          author_handle: "someone",
          text: "How did you decide where ownership should live?",
          posted_at: now
        }
      ])

    account |> Engage.list_engagements() |> hd()
  end

  defp request_prompt(conn) do
    {:ok, raw, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(raw) |> get_in(["messages", Access.at(0), "content"])
  end

  defp reply(conn, text) do
    response = %{
      "content" => [
        %{
          "type" => "tool_use",
          "name" => "respond",
          "input" => %{"reply" => text}
        }
      ]
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(response))
  end
end
