defmodule SuperXWeb.TeamInvitationController do
  @moduledoc """
  The bearer-link boundary between an invitation and an ordinary X sign-in.

  Viewing never changes membership. A signed-out visitor returns to the same
  link after X OAuth, then explicitly accepts with the account they signed into.
  """

  use SuperXWeb, :controller

  alias SuperX.Teams

  def show(conn, %{"token" => token}) do
    render(conn, :show,
      invitation: Teams.get_invitation(token),
      token: token,
      acceptance_form: Phoenix.Component.to_form(%{}, as: :acceptance),
      x_configured: SuperX.X.configured?()
    )
  end

  def accept(%{assigns: %{current_user: nil}} = conn, %{"token" => token}) do
    conn
    |> put_flash(:error, "Sign in with X before accepting this invitation.")
    |> redirect(to: ~p"/team/invitations/#{token}")
  end

  def accept(conn, %{"token" => token}) do
    case Teams.accept_invitation(conn.assigns.current_user, token) do
      {:ok, _member} ->
        conn
        |> put_flash(:info, "Invitation accepted. Your account now uses the owner's plan.")
        |> redirect(to: ~p"/accounts")

      {:error, reason} ->
        conn
        |> put_flash(:error, acceptance_error(reason))
        |> redirect(to: ~p"/team/invitations/#{token}")
    end
  end

  defp acceptance_error(:expired),
    do: "That invitation has expired. Ask the owner for a new link."

  defp acceptance_error(:already_accepted), do: "That invitation has already been accepted."
  defp acceptance_error(:already_member), do: "This account already belongs to a team."

  defp acceptance_error(:invitee_owns_team),
    do: "A team owner cannot become another owner's member."

  defp acceptance_error(:self_membership), do: "You cannot accept your own invitation."
  defp acceptance_error(_reason), do: "That invitation is no longer available."
end
