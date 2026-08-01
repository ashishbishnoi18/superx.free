defmodule SuperXWeb.DMsLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.Accounts
  alias SuperX.X

  setup %{conn: conn} do
    previous = Application.get_env(:superx, X, [])
    Application.put_env(:superx, X, Keyword.put(previous, :dm_enabled, false))
    on_exit(fn -> Application.put_env(:superx, X, previous) end)

    %{user: user, account: account} = user_fixture()

    {:ok, user} =
      Accounts.update_user(user, %{
        onboarding_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, token} = Accounts.create_session(user)
    conn = init_test_session(conn, %{user_token: token})

    %{conn: conn, user: user, account: account}
  end

  test "renders a specific empty state while the flag is off", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dms")

    assert has_element?(view, "#dm-availability")
    assert has_element?(view, "#dms-empty-state")
    refute has_element?(view, "#dms-inbox")
  end

  test "renders a stored conversation and thread with stable controls", %{
    conn: conn,
    account: account
  } do
    conversation = dm_conversation_fixture(account)
    dm_message_fixture(account, conversation)

    {:ok, view, _html} = live(conn, ~p"/dms?conversation=#{conversation.id}")

    assert has_element?(view, "#dms-inbox")
    assert has_element?(view, "#dm-thread")
    assert has_element?(view, "#dm-reply-form")
    assert has_element?(view, "#dm-send-reply[disabled]")
  end
end
