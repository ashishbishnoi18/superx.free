defmodule SuperXWeb.UserAuth do
  @moduledoc """
  Session handling for both plug pipelines and LiveView mounts.
  """

  use SuperXWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias SuperX.Accounts

  # Deliberately long-lived: this is a daily-use tool and re-authorising
  # through X on every visit would be hostile.
  @max_age 60 * 60 * 24 * 60
  @cookie "_superx_session"
  @cookie_options [sign: true, max_age: @max_age, same_site: "Lax", http_only: true]

  @doc """
  Logs a user in, rotating the session to defend against fixation.
  """
  def log_in_user(conn, user, redirect_to \\ nil) do
    {:ok, token} =
      Accounts.create_session(user, %{
        user_agent: get_user_agent(conn),
        ip: get_ip(conn)
      })

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> redirect(to: redirect_to || signed_in_path(user))
  end

  @doc "Logs the current user out and drops their session server-side."
  def log_out_user(conn) do
    if token = get_session(conn, :user_token), do: Accounts.delete_session_token(token)

    conn
    |> renew_session()
    |> delete_resp_cookie(@cookie, @cookie_options)
    |> redirect(to: ~p"/")
  end

  @doc "Assigns `:current_user` from the session, or nil."
  def fetch_current_user(conn, _opts) do
    {token, conn} = ensure_user_token(conn)
    user = token && Accounts.get_user_by_session_token(token)
    assign(conn, :current_user, user)
  end

  @doc "Halts with a redirect to sign-in when nobody is logged in."
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "Please sign in to continue.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  @doc "Sends already-authenticated users straight into the app."
  def redirect_if_authenticated(conn, _opts) do
    if user = conn.assigns[:current_user] do
      conn |> redirect(to: signed_in_path(user)) |> halt()
    else
      conn
    end
  end

  # --- LiveView ------------------------------------------------------------

  @doc """
  LiveView mount hooks.

    * `:mount_current_user` — assigns the user if present
    * `:ensure_authenticated` — redirects to sign-in when absent
    * `:ensure_onboarded` — additionally requires a connected X account
  """
  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "Please sign in to continue.")
       |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end

  def on_mount(:ensure_onboarded, _params, session, socket) do
    socket = mount_current_user(socket, session)

    cond do
      is_nil(socket.assigns.current_user) ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}

      socket.assigns.current_x_account == nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/connect")}

      true ->
        {:cont, socket}
    end
  end

  defp mount_current_user(socket, session) do
    socket
    |> Phoenix.Component.assign_new(:current_user, fn ->
      Accounts.get_user_by_session_token(session["user_token"])
    end)
    |> then(fn socket ->
      Phoenix.Component.assign_new(socket, :current_x_account, fn ->
        case socket.assigns.current_user do
          nil -> nil
          user -> Accounts.current_x_account(user)
        end
      end)
    end)
  end

  # --- Internals -----------------------------------------------------------

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
    |> put_resp_cookie(@cookie, token, @cookie_options)
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@cookie])

      case conn.cookies[@cookie] do
        nil -> {nil, conn}
        token -> {token, put_session(conn, :user_token, token)}
      end
    end
  end

  # Preserves flash and return_to while discarding everything else.
  defp renew_session(conn) do
    preserved = Map.take(get_session(conn), ["phoenix_flash", :user_return_to])

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> then(fn conn ->
      Enum.reduce(preserved, conn, fn {key, value}, acc -> put_session(acc, key, value) end)
    end)
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  # Where someone lands depends on how far through setup they are: no
  # account means connect, connected but not set up means the guided flow,
  # otherwise Home.
  defp signed_in_path(user) do
    cond do
      is_nil(Accounts.current_x_account(user)) -> ~p"/connect"
      is_nil(user.onboarding_completed_at) -> ~p"/welcome"
      true -> ~p"/home"
    end
  end

  defp get_user_agent(conn) do
    conn |> get_req_header("user-agent") |> List.first() |> truncate(255)
  end

  defp get_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp truncate(nil, _), do: nil
  defp truncate(string, max), do: String.slice(string, 0, max)
end
