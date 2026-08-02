defmodule SuperXWeb.EngageLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Content, Engage}

  setup %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, token} = Accounts.create_session(user)

    %{conn: init_test_session(conn, %{user_token: token}), user: user, account: account}
  end

  test "adds ready-made and custom feeds and changes their ranking", %{
    conn: conn,
    account: account
  } do
    configure_read_api()
    test_process = self()

    Req.Test.stub(SuperX.TwitterAPI, fn conn ->
      send(test_process, {:feed_request_started, self()})

      receive do
        :finish_feed_request -> empty_tweets(conn)
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/engage?kind=feed")

    assert has_element?(view, "#feed-starters")
    assert has_element?(view, "#feed-search-form")

    view |> element("#starter-artificial-intelligence") |> render_click()
    finish_request(view, :feed_request_started, :finish_feed_request)

    assert [feed] = Engage.list_feeds(account)
    assert feed.name == "Artificial Intelligence"
    assert has_element?(view, "#topic-feed-#{feed.id}")
    assert has_element?(view, "#starter-artificial-intelligence[disabled]")

    view |> element("#feed-#{feed.id}-newest") |> render_click()

    assert Engage.list_feeds(account) |> hd() |> Map.fetch!(:ranking) == "newest"
    assert has_element?(view, "#feed-#{feed.id}-newest.act-key")

    view
    |> form("#feed-search-form", feed: %{query: "elixir deployment"})
    |> render_submit()

    finish_request(view, :feed_request_started, :finish_feed_request)

    assert Engage.list_feeds(account) |> Enum.map(& &1.query) |> Enum.sort() ==
             Enum.sort([feed.query, "elixir deployment"])
  end

  test "an unconfigured empty inbox says why it cannot fill", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/engage?kind=mention")

    assert has_element?(view, "#engage-empty-unconfigured")
    refute has_element?(view, "#engage-empty-current")
  end

  test "adding a feed fetches it immediately rather than waiting for the poll", %{
    conn: conn,
    account: account
  } do
    # A feed nobody has fetched looks identical to a broken one. The
    # scheduled poll is up to twenty minutes away, which is long enough for
    # someone to conclude the feature does not work.
    configure_read_api()
    test_process = self()

    Req.Test.stub(SuperX.TwitterAPI, fn conn ->
      send(test_process, {:feed_request_started, self()})

      receive do
        :finish_feed_request -> empty_tweets(conn)
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/engage?kind=feed")

    view
    |> element("button", "Artificial Intelligence")
    |> render_click()

    feed = SuperX.Engage.list_feeds(account) |> List.first()
    assert feed
    finish_request(view, :feed_request_started, :finish_feed_request)

    # touch_feed/1 only runs after a fetch has actually happened.
    assert SuperX.Engage.get_feed(account, feed.id).last_synced_at != nil
  end

  test "refreshes mentions now and shows that the requested read is in progress", %{
    conn: conn,
    account: account
  } do
    configure_read_api()
    test_process = self()

    Req.Test.stub(SuperX.TwitterAPI, fn conn ->
      send(test_process, {:mention_request_started, self()})

      receive do
        :finish_mention_request ->
          tweet = %{
            "id" => "mention-now",
            "text" => "Can you explain this?",
            "createdAt" => "Wed Oct 10 20:19:24 +0000 2018",
            "author" => %{
              "userName" => "curious",
              "name" => "Curious",
              "followers" => 120
            }
          }

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{"tweets" => [tweet], "has_next_page" => false})
          )
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/engage?kind=mention")

    view |> element("#refresh-mentions") |> render_click()
    assert_receive {:mention_request_started, request_process}
    assert has_element?(view, "#refresh-mentions[disabled]", "Refreshing…")

    ref = Process.monitor(request_process)
    send(request_process, :finish_mention_request)
    assert_receive {:DOWN, ^ref, :process, ^request_process, :normal}
    _ = :sys.get_state(view.pid)

    assert account
           |> Engage.list_engagements(kind: "mention")
           |> Enum.any?(&(&1.x_post_id == "mention-now"))

    assert has_element?(view, "#engagement-mention-now")
  end

  test "keeps sent and failed replies reachable with their text and a retry", %{
    conn: conn,
    user: user,
    account: account
  } do
    {1, _} =
      Engage.upsert_many([
        %{
          x_account_id: account.id,
          kind: "mention",
          x_post_id: "reply-target",
          author_handle: "someone",
          text: "What happened?",
          posted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])

    [engagement] = Engage.list_engagements(account)

    {:ok, draft} =
      Engage.create_draft(%{
        engagement_id: engagement.id,
        user_id: user.id,
        text: "The boundary was in the wrong place."
      })

    {:ok, view, _html} = live(conn, ~p"/engage?kind=mention")
    view |> element("#send-reply-#{draft.id}") |> render_click()

    [reply] = Content.list_posts(account, "scheduled")

    # A duplicate browser event must not turn one approved draft into two
    # local posts (or two replies if the clock crosses a second boundary).
    render_click(view, "send", %{"draft_id" => draft.id})
    assert Content.list_posts(account, "scheduled") == [reply]
    assert Content.list_posts(account, "draft") == []

    {:ok, _failed} = Content.mark_failed(reply, "X returned 400: duplicate content")

    render_patch(view, ~p"/engage?kind=replied")

    assert has_element?(view, "#engagement-reply-target")
    assert has_element?(view, "a[href='/engage?kind=replied']", "My replies")
    assert has_element?(view, "#reply-post-#{reply.id}", "The boundary was in the wrong place.")

    assert has_element?(
             view,
             "#reply-post-#{reply.id}-error",
             "X returned 400: duplicate content"
           )

    assert has_element?(view, "#edit-reply-#{reply.id}[href='/queue/#{reply.id}']")

    view |> element("#retry-reply-#{reply.id}") |> render_click()

    retried = Content.get_post(user, account, reply.id)
    assert retried.status == "scheduled"

    assert [%{"text" => "The boundary was in the wrong place.", "media_ids" => []}] =
             retried.segments
  end

  defp configure_read_api do
    previous = Application.get_env(:superx, SuperX.TwitterAPI, [])

    Application.put_env(
      :superx,
      SuperX.TwitterAPI,
      Keyword.merge(previous, api_key: "test-key", min_interval_ms: 0)
    )

    on_exit(fn -> Application.put_env(:superx, SuperX.TwitterAPI, previous) end)
  end

  defp finish_request(view, started_message, finish_message) do
    assert_receive {^started_message, request_process}
    ref = Process.monitor(request_process)
    send(request_process, finish_message)
    assert_receive {:DOWN, ^ref, :process, ^request_process, :normal}
    _ = :sys.get_state(view.pid)
    :ok
  end

  defp empty_tweets(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"tweets" => [], "has_next_page" => false}))
  end
end
