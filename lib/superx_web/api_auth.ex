defmodule SuperXWeb.ApiAuth do
  @moduledoc """
  Bearer authentication for the programmatic API.

  API tokens identify a user, then the same selected-account resolution as
  the browser decides which X account the endpoints expose.
  """

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  alias SuperX.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, encoded} <- bearer_token(conn),
         user when not is_nil(user) <- Accounts.get_user_by_api_token(encoded) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_x_account, Accounts.current_x_account(user))
    else
      _reason -> unauthorised(conn)
    end
  end

  defp bearer_token(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         true <- String.downcase(scheme) == "bearer",
         false <- token == "" do
      {:ok, token}
    else
      _ -> :error
    end
  end

  defp unauthorised(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "Provide a valid API token as a Bearer credential."})
    |> halt()
  end
end
