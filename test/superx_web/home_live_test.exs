defmodule SuperXWeb.HomeLiveTest do
  use SuperXWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Billing, Content}

  setup %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, token} = Accounts.create_session(user)

    %{conn: init_test_session(conn, %{user_token: token}), user: user, account: account}
  end

  test "a new account gets a first-publishing mission instead of misleading empty widgets", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/home")

    assert has_element?(view, "#getting-started", "Create and review your first draft")
    assert has_element?(view, "#getting-started a[href='/voice']", "Set up voice")

    assert has_element?(
             view,
             "#home-shelf-empty",
             "No drafts can be written yet. Set up your voice first"
           )

    refute has_element?(view, "#home-shelf-empty", "writes new ones overnight")
  end

  test "Home actions cannot mutate another selected account's shelf", %{
    conn: conn,
    user: user,
    account: account
  } do
    {:ok, _subscription} =
      Billing.upsert_subscription(user, %{tier: "pro", status: "active"})

    {:ok, second_account} =
      SuperX.Accounts.Connect.attach(
        user,
        %{
          x_user_id: "home-second-#{System.unique_integer([:positive])}",
          handle: "home_second"
        },
        %{access_token: "second-token"}
      )

    {:ok, generation} =
      Content.create_generation(%{
        user_id: user.id,
        x_account_id: second_account.id,
        segments: [%{"text" => "This belongs to the other selected account."}]
      })

    {:ok, view, _html} = live(conn, ~p"/home")
    render_click(view, "accept", %{"id" => generation.id})

    assert Content.get_generation(user, second_account, generation.id).status == "shelf"
    assert Content.list_posts(second_account, "scheduled") == []
    assert account.id != second_account.id
  end
end
