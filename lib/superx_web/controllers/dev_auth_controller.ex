defmodule SuperXWeb.DevAuthController do
  @moduledoc """
  Development-only sign-in, so the app can be exercised before X OAuth
  credentials exist.

  Routed only when `:dev_routes` is enabled, and refuses to run outside
  the dev environment even if something else mounts it.
  """

  use SuperXWeb, :controller

  alias SuperX.Accounts

  def create(conn, %{"id" => id}) do
    if Application.get_env(:superx, :dev_routes) do
      case Accounts.get_user(id) do
        nil -> conn |> put_flash(:error, "No such demo user.") |> redirect(to: ~p"/")
        user -> SuperXWeb.UserAuth.log_in_user(conn, user)
      end
    else
      conn |> put_status(:not_found) |> text("not found")
    end
  end
end
