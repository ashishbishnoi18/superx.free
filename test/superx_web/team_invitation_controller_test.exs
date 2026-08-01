defmodule SuperXWeb.TeamInvitationControllerTest do
  use SuperXWeb.ConnCase, async: true

  import SuperX.Fixtures

  alias SuperX.{Accounts, Billing, Teams}

  test "shows the separation boundary before acceptance", %{conn: conn} do
    %{user: owner} = user_fixture()
    {:ok, invitation, _url} = Teams.invite(owner, %{"email" => "invitee@example.com"})

    document =
      conn
      |> get(~p"/team/invitations/#{invitation.token}")
      |> html_response(200)
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query("#team-invitation") |> Enum.any?()
    assert document |> LazyHTML.query("#accept-team-invitation-form") |> Enum.empty?()
  end

  test "a signed-in invitee accepts and is redirected to Accounts", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: invitee} = user_fixture()
    {:ok, invitation, _url} = Teams.invite(owner, %{"email" => "accepted@example.com"})
    {:ok, token} = Accounts.create_session(invitee)
    conn = init_test_session(conn, %{user_token: token})

    conn = post(conn, ~p"/team/invitations/#{invitation.token}/accept")

    assert redirected_to(conn) == ~p"/accounts"
    assert Billing.seat_count(owner) == 1
  end
end
