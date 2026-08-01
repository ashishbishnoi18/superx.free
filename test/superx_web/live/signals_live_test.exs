defmodule SuperXWeb.SignalsLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Signals}

  test "an existing agent can change where future contacts are filed", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, token} = Accounts.create_session(user)
    conn = init_test_session(conn, %{user_token: token})

    {:ok, list} = Signals.create_contact_list(account, %{name: "Prospects"})
    {:ok, agent} = Signals.create_agent(account, %{kind: "keyword", target: "postgres"})
    {:ok, view, _html} = live(conn, ~p"/signals")

    view
    |> form("#agent-list-form-#{agent.id}", filing: %{contact_list_id: list.id})
    |> render_change()

    assert Signals.get_agent(account, agent.id).contact_list_id == list.id
  end
end
