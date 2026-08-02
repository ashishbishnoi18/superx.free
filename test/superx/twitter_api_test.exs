defmodule SuperX.TwitterAPITest do
  @moduledoc """
  The client bills per record and paces against a rate limit, so the
  things worth pinning are the ones that cost money when wrong: envelope
  handling, the paging ceiling, and the parameter names the published docs
  get wrong.
  """

  # Reads go through the persistent cache, so these need a database even
  # though what they assert is HTTP behaviour.
  use SuperX.DataCase, async: true

  alias SuperX.TwitterAPI

  setup do
    previous = Application.get_env(:superx, TwitterAPI, [])

    Application.put_env(
      :superx,
      TwitterAPI,
      Keyword.merge(previous, api_key: "test-key", min_interval_ms: 0)
    )

    on_exit(fn -> Application.put_env(:superx, TwitterAPI, previous) end)
    :ok
  end

  defp stub(fun), do: Req.Test.stub(TwitterAPI, fun)

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp tweet(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "text" => "post #{id}",
        "createdAt" => "Wed Oct 10 20:19:24 +0000 2018",
        "likeCount" => 10,
        "author" => %{"userName" => "someone", "name" => "Someone", "followers" => 100}
      },
      overrides
    )
  end

  describe "response envelopes" do
    test "reads tweets from the top level, as advanced_search returns them" do
      stub(fn conn ->
        json(conn, %{"tweets" => [tweet("1"), tweet("2")], "has_next_page" => false})
      end)

      assert {:ok, [%{"id" => "1"}, %{"id" => "2"}]} = TwitterAPI.search("elixir", max: 40)
    end

    test "reads tweets nested under data, as last_tweets returns them" do
      stub(fn conn ->
        json(conn, %{"data" => %{"tweets" => [tweet("3")], "pin_tweet" => nil}})
      end)

      assert {:ok, [%{"id" => "3"}]} = TwitterAPI.user_tweets("someone", max: 40)
    end

    test "treats a non-list payload as empty rather than crashing" do
      # `data` as a bare map is what broke this the first time: it was
      # concatenated onto a list and blew up in length/1.
      stub(fn conn -> json(conn, %{"data" => %{"unexpected" => "shape"}}) end)

      assert {:ok, []} = TwitterAPI.search("elixir", max: 40)
    end
  end

  describe "paging" do
    test "stops at the requested ceiling even when more pages exist" do
      stub(fn conn ->
        json(conn, %{
          "tweets" => Enum.map(1..20, &tweet(to_string(&1))),
          "has_next_page" => true,
          "next_cursor" => "more"
        })
      end)

      assert {:ok, tweets} = TwitterAPI.search("elixir", max: 5)
      assert length(tweets) == 5
    end

    test "follows the cursor until the ceiling is reached" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(fn conn ->
        n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

        json(conn, %{
          "tweets" => [tweet("page#{n}")],
          "has_next_page" => true,
          "next_cursor" => "cursor#{n}"
        })
      end)

      assert {:ok, tweets} = TwitterAPI.search("elixir", max: 3)
      assert length(tweets) == 3
      assert Agent.get(counter, & &1) == 3
    end

    test "stops when a page comes back empty even if the API claims more" do
      stub(fn conn ->
        json(conn, %{"tweets" => [], "has_next_page" => true, "next_cursor" => "loop"})
      end)

      assert {:ok, []} = TwitterAPI.search("elixir", max: 40)
    end

    test "returns what it already paid for when a later page fails" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(fn conn ->
        case Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) do
          1 ->
            json(conn, %{"tweets" => [tweet("1")], "has_next_page" => true, "next_cursor" => "c"})

          _ ->
            Plug.Conn.send_resp(conn, 500, "boom")
        end
      end)

      assert {:ok, [%{"id" => "1"}]} = TwitterAPI.search("elixir", max: 10)
    end
  end

  describe "request shape" do
    test "passes the selected search ranking to the provider" do
      stub(fn conn ->
        params = Plug.Conn.fetch_query_params(conn).query_params
        assert params["queryType"] == "Latest"
        json(conn, %{"tweets" => []})
      end)

      assert {:ok, []} = TwitterAPI.search("elixir", max: 40, type: "Latest")
    end

    test "mentions sends userName, not the screen_name the docs claim" do
      stub(fn conn ->
        params = Plug.Conn.fetch_query_params(conn).query_params
        assert params["userName"] == "someone"
        refute Map.has_key?(params, "screen_name")
        json(conn, %{"tweets" => []})
      end)

      assert {:ok, []} = TwitterAPI.mentions("@someone", max: 40)
    end

    test "engagement filters are pushed into the query, not applied locally" do
      stub(fn conn ->
        query = Plug.Conn.fetch_query_params(conn).query_params["query"]
        assert query =~ "min_faves:500"
        assert query =~ "lang:en"
        assert query =~ "-filter:replies"
        json(conn, %{"tweets" => []})
      end)

      assert {:ok, []} = TwitterAPI.search("elixir", max: 40, min_likes: 500, lang: "en")
    end
  end

  describe "errors" do
    test "surfaces exhausted credits distinctly so callers can stop retrying" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 402, ~s({"error":"no credits"})) end)

      assert {:error, :out_of_credits} = TwitterAPI.search("elixir", max: 40)
    end

    test "surfaces auth failure distinctly" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 401, "nope") end)

      assert {:error, :unauthorized} = TwitterAPI.search("elixir", max: 40)
    end

    test "refuses to call at all without a key" do
      previous = Application.get_env(:superx, TwitterAPI, [])
      Application.put_env(:superx, TwitterAPI, Keyword.put(previous, :api_key, nil))
      on_exit(fn -> Application.put_env(:superx, TwitterAPI, previous) end)

      refute TwitterAPI.configured?()
      assert {:error, :not_configured} = TwitterAPI.search("elixir", max: 40)
    end
  end

  describe "normalisation" do
    test "maps a tweet onto the corpus shape" do
      attrs =
        TwitterAPI.to_corpus_attrs(
          tweet("9", %{
            "likeCount" => 500,
            "retweetCount" => 20,
            "conversationId" => "9",
            "replyCount" => 3,
            "author" => %{
              "userName" => "levelsio",
              "name" => "levelsio",
              "followers" => 900_000,
              "isBlueVerified" => true,
              "profilePicture" => "https://x.com/a_normal.jpg"
            }
          })
        )

      assert attrs.x_post_id == "9"
      assert attrs.author_handle == "levelsio"
      assert attrs.likes == 500
      assert attrs.author_verified
      assert attrs.source == "twitterapi.io"
      # A post that opens its own conversation and drew replies is a thread.
      assert attrs.is_thread
      # The 48px thumbnail is upscaled for the UI.
      assert attrs.author_avatar_url == "https://x.com/a_400x400.jpg"
    end

    test "parses X's date format" do
      attrs = TwitterAPI.to_corpus_attrs(tweet("1"))
      assert attrs.posted_at == ~U[2018-10-10 20:19:24Z]
    end

    test "falls back to now on an unparseable date rather than dropping the post" do
      attrs = TwitterAPI.to_corpus_attrs(tweet("1", %{"createdAt" => "not a date"}))
      assert DateTime.diff(DateTime.utc_now(), attrs.posted_at) < 5
    end
  end

  describe "endpoints verified against the live API" do
    test "the list watch reads /twitter/list/tweets" do
      # /twitter/list/tweets_timeline answers 200 with an empty tweets array
      # and status "success", so the list watch found nothing and reported
      # no error. Confirmed against the live API: only /twitter/list/tweets
      # returns posts.
      stub(fn conn ->
        assert conn.request_path == "/twitter/list/tweets"
        json(conn, %{"tweets" => [tweet("1")], "has_next_page" => false})
      end)

      assert {:ok, [%{"id" => "1"}]} = TwitterAPI.list_timeline("123", max: 40)
    end

    test "replies come back under tweets, whatever the docs say" do
      # The published reference describes a "replies" array. The live API
      # returns "tweets"; reading the documented key would yield an empty
      # list rather than an error.
      stub(fn conn ->
        assert conn.request_path == "/twitter/tweet/replies"
        json(conn, %{"tweets" => [tweet("9")], "has_next_page" => false})
      end)

      assert {:ok, [%{"id" => "9"}]} = TwitterAPI.replies("555", max: 40)
    end
  end
end
