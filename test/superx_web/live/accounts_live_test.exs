defmodule SuperXWeb.AccountsLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.Accounts
  alias SuperX.Teams

  test "renders the persisted theme on the root before LiveView connects", %{conn: conn} do
    %{user: user} = user_fixture()
    {:ok, user} = Accounts.update_theme(user, "dark")
    {:ok, session_token} = Accounts.create_session(user)

    document =
      conn
      |> init_test_session(%{user_token: session_token})
      |> get(~p"/accounts")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert ["dark"] = document |> LazyHTML.query("html") |> LazyHTML.attribute("data-theme")
  end

  test "persists appearance and manages tokens without revealing them again", %{conn: conn} do
    %{user: user} = user_fixture()
    {:ok, session_token} = Accounts.create_session(user)
    conn = init_test_session(conn, %{user_token: session_token})

    {:ok, view, _html} = live(conn, ~p"/accounts")

    assert has_element?(view, "#appearance-settings")
    assert has_element?(view, "#theme-system")
    assert has_element?(view, "#api-tokens-empty")

    view |> element("#theme-system") |> render_click()
    assert Accounts.get_user!(user.id) |> Accounts.theme() == "system"

    view
    |> form("#api-token-form", api_token: %{name: "Dashboard export"})
    |> render_submit()

    assert has_element?(view, "#new-api-token")
    [api_token] = Accounts.list_api_tokens(user)
    assert has_element?(view, "#api-token-#{api_token.id}")

    view
    |> element("#api-token-#{api_token.id} button[phx-click=revoke_api_token]")
    |> render_click()

    assert %DateTime{} = Accounts.list_api_tokens(user) |> List.first() |> Map.fetch!(:revoked_at)
    refute has_element?(view, "#api-token-#{api_token.id} button[phx-click=revoke_api_token]")
  end

  test "creates copyable invitations and manages accepted members", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: member} = user_fixture()
    {:ok, session_token} = Accounts.create_session(owner)
    conn = init_test_session(conn, %{user_token: session_token})

    {:ok, view, _html} = live(conn, ~p"/accounts")

    assert has_element?(view, "#team-settings")
    assert has_element?(view, "#team-members-empty")
    assert has_element?(view, "#team-invitations-empty")

    view
    |> form("#team-invitation-form", invitation: %{email: "member@example.com"})
    |> render_submit()

    [invitation] = Teams.list_invitations(owner)
    assert has_element?(view, "#team-invitation-#{invitation.id}")
    assert has_element?(view, "#invitation-link-#{invitation.id}[readonly]")

    assert {:ok, _member} = Teams.accept_invitation(member, invitation.token)
    {:ok, view, _html} = live(conn, ~p"/accounts")

    assert has_element?(view, "#team-member-#{member.id}")

    view
    |> element("#team-member-#{member.id} button[phx-click=remove_member]")
    |> render_click()

    assert has_element?(view, "#team-members-empty")
  end

  test "shows inherited entitlement without an invitation form to members", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: member} = user_fixture()
    {:ok, invitation, _url} = Teams.invite(owner, %{"email" => "member-view@example.com"})
    assert {:ok, _member} = Teams.accept_invitation(member, invitation.token)
    {:ok, session_token} = Accounts.create_session(member)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{user_token: session_token})
      |> live(~p"/accounts")

    assert has_element?(view, "#team-membership")
    refute has_element?(view, "#team-invitation-form")
  end
end
