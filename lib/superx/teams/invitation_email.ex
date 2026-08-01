defmodule SuperX.Teams.InvitationEmail do
  @moduledoc """
  The optional delivery path for a team invitation.

  The email contains the same persistent link shown to the owner. Delivery is
  an extra convenience, never the only way into a team.
  """

  import Swoosh.Email

  alias SuperX.Accounts.User
  alias SuperX.Teams.Invitation

  def build(%User{} = owner, %Invitation{} = invitation, url) do
    owner_name = owner.name || "A SuperX user"

    new()
    |> to(invitation.email)
    |> from({"SuperX", sender_address()})
    |> subject("#{owner_name} invited you to SuperX")
    |> text_body("""
    #{owner_name} invited you to use your own SuperX account under their subscription.

    Accept the invitation:
    #{url}

    This link expires #{Calendar.strftime(invitation.expires_at, "%-d %B %Y at %H:%M UTC")}.
    """)
  end

  defp sender_address do
    host = URI.parse(SuperXWeb.Endpoint.url()).host || "localhost"
    "noreply@#{host}"
  end
end
