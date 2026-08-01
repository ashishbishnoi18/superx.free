defmodule SuperXWeb.UpgradeLiveTest do
  use SuperXWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Teams}

  test "surfaces accepted seat count, discount, and per-plan pricing", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: first} = user_fixture()
    %{user: second} = user_fixture()
    accept(owner, first, "first@example.com")
    accept(owner, second, "second@example.com")
    {:ok, session_token} = Accounts.create_session(owner)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{user_token: session_token})
      |> live(~p"/upgrade")

    assert has_element?(view, "#seat-pricing")
    assert has_element?(view, "#seat-count[data-seat-count='2'][data-discount='25']")
    assert has_element?(view, "#pro-seat-price")
  end

  test "shows a member's owner-managed seat without checkout actions", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: member} = user_fixture()
    accept(owner, member, "member@example.com")
    {:ok, session_token} = Accounts.create_session(member)

    {:ok, view, _html} =
      conn
      |> init_test_session(%{user_token: session_token})
      |> live(~p"/upgrade")

    assert has_element?(view, "#seat-count[data-seat-count='1']")
    refute has_element?(view, "button[phx-click=checkout]")
    refute has_element?(view, "button[phx-click=manage]")
  end

  defp accept(owner, member, email) do
    {:ok, invitation, _url} = Teams.invite(owner, %{"email" => email})
    {:ok, _member} = Teams.accept_invitation(member, invitation.token)
  end
end
