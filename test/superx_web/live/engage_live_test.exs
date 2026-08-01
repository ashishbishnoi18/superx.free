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
end
