defmodule SuperXWeb.SettingsLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Repo}
  alias SuperX.Accounts.User

  setup %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, token} = Accounts.create_session(user)

    %{conn: init_test_session(conn, %{user_token: token}), user: user, account: account}
  end

  test "the random delay select persists the publish jitter", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#queue-jitter option[value='0'][selected]")

    view
    |> form("#queue-jitter-form", %{minutes: "3"})
    |> render_change()

    assert Repo.get!(User, user.id).settings["queue_jitter_minutes"] == 3
    assert has_element?(view, "#queue-jitter option[value='3'][selected]")

    view
    |> form("#queue-jitter-form", %{minutes: "0"})
    |> render_change()

    assert Repo.get!(User, user.id).settings["queue_jitter_minutes"] == 0
  end
end
