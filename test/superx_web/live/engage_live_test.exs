defmodule SuperXWeb.EngageLiveTest do
  use SuperXWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Engage}

  setup %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, token} = Accounts.create_session(user)

    %{conn: init_test_session(conn, %{user_token: token}), account: account}
  end

  test "adds ready-made and custom feeds and changes their ranking", %{
    conn: conn,
    account: account
  } do
    {:ok, view, _html} = live(conn, ~p"/engage?kind=feed")

    assert has_element?(view, "#feed-starters")
    assert has_element?(view, "#feed-search-form")

    view |> element("#starter-artificial-intelligence") |> render_click()

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

    assert Engage.list_feeds(account) |> Enum.map(& &1.query) |> Enum.sort() ==
             Enum.sort([feed.query, "elixir deployment"])
  end

  test "adding a feed fetches it immediately rather than waiting for the poll", %{
    conn: conn,
    account: account
  } do
    # A feed nobody has fetched looks identical to a broken one. The
    # scheduled poll is up to twenty minutes away, which is long enough for
    # someone to conclude the feature does not work.
    previous = Application.get_env(:superx, SuperX.TwitterAPI, [])

    Application.put_env(
      :superx,
      SuperX.TwitterAPI,
      Keyword.merge(previous, api_key: "test-key", min_interval_ms: 0)
    )

    on_exit(fn -> Application.put_env(:superx, SuperX.TwitterAPI, previous) end)

    Req.Test.stub(SuperX.TwitterAPI, fn c ->
      c
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"tweets" => [], "has_next_page" => false}))
    end)

    {:ok, view, _html} = live(conn, ~p"/engage?kind=feed")

    view
    |> element("button", "Artificial Intelligence")
    |> render_click()

    feed = SuperX.Engage.list_feeds(account) |> List.first()
    assert feed

    # touch_feed/1 only runs after a fetch has actually happened.
    assert_eventually(fn ->
      SuperX.Engage.get_feed(account, feed.id).last_synced_at != nil
    end)
  end

  defp assert_eventually(fun, attempts \\ 40) do
    if fun.() do
      :ok
    else
      if attempts == 0 do
        flunk("condition never became true")
      else
        Process.sleep(50)
        assert_eventually(fun, attempts - 1)
      end
    end
  end
end
