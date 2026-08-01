defmodule SuperXWeb.AccountsLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.Accounts

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
end
