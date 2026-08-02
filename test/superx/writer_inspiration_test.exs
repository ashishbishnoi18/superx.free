defmodule SuperX.Content.WriterInspirationTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures

  alias SuperX.{AI, Content, TwitterAPI}
  alias SuperX.Content.{Voice, Writer}

  setup do
    previous_ai = Application.get_env(:superx, AI, [])
    previous_twitter = Application.get_env(:superx, TwitterAPI, [])

    Application.put_env(
      :superx,
      AI,
      Keyword.merge(previous_ai,
        api_key: "test-key",
        base_url: "https://api.anthropic.test",
        writer_model: "writer-test"
      )
    )

    Application.put_env(
      :superx,
      TwitterAPI,
      Keyword.merge(previous_twitter, api_key: "test-key", min_interval_ms: 0)
    )

    on_exit(fn ->
      Application.put_env(:superx, AI, previous_ai)
      Application.put_env(:superx, TwitterAPI, previous_twitter)
    end)

    user_fixture()
  end

  test "creator phrasing is discarded and the paid read is reused", %{
    user: user,
    account: account
  } do
    counter = start_supervised!({Agent, fn -> %{ai: 0, twitter: 0} end})
    handle = "ideas#{System.unique_integer([:positive])}"
    # A complete short sentence has no six-word run and no five-word
    # opening. It still cannot be published verbatim under another name.
    creator_post = "Boring defaults build trust."

    {:ok, profile} = Content.get_or_create_voice_profile(account)

    {:ok, profile} =
      Content.update_voice_profile(profile, %{
        topics: "software",
        inspiration_handles: [handle]
      })

    Req.Test.stub(TwitterAPI, fn conn ->
      Agent.update(counter, &Map.update!(&1, :twitter, fn n -> n + 1 end))
      params = Plug.Conn.fetch_query_params(conn).query_params
      assert params["userName"] == handle

      json(conn, %{
        "data" => %{"tweets" => [%{"id" => "creator-1", "text" => creator_post}]}
      })
    end)

    Req.Test.stub(AI, fn conn ->
      request = read_request(conn)
      prompt = get_in(request, ["messages", Access.at(0), "content"])

      attempt =
        Agent.get_and_update(counter, &{&1.ai + 1, Map.update!(&1, :ai, fn n -> n + 1 end)})

      case attempt do
        1 ->
          assert prompt =~ "<creator_idea_material>"
          assert prompt =~ creator_post
          ai_reply(conn, creator_post)

        2 ->
          refute prompt =~ "<creator_idea_material>"
          refute prompt =~ creator_post
          ai_reply(conn, "Clear ownership makes software easier to change.")
      end
    end)

    assert {:ok, generation} =
             Writer.generate(user, account, topic: "software teams", source: nil)

    assert generation.segments == [
             %{"media_ids" => [], "text" => "Clear ownership makes software easier to change."}
           ]

    # A second consumer reaches the same TwitterAPI cache key rather than
    # buying the creator's records again.
    assert [%{handle: ^handle, posts: [^creator_post]}] = Voice.inspiration_posts(profile)
    assert Agent.get(counter, & &1) == %{ai: 2, twitter: 1}
  end

  defp read_request(conn) do
    {:ok, raw, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(raw)
  end

  defp ai_reply(conn, text) do
    json(conn, %{
      "content" => [
        %{
          "type" => "tool_use",
          "name" => "respond",
          "input" => %{"segments" => [text]}
        }
      ]
    })
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
