defmodule SuperXWeb.VoiceLiveTest do
  use SuperXWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Content}

  test "says when an empty account was learned from its profile rather than posts", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    profile = Content.get_voice_profile(account)
    {:ok, token} = Accounts.create_session(user)
    conn = init_test_session(conn, %{user_token: token})

    {:ok, view, _html} = live(conn, ~p"/voice")
    send(view.pid, {:derived, {:ok, profile}})

    assert has_element?(
             view,
             "#flash-info",
             "Built a starting voice from your profile; no posts were available."
           )
  end
end
