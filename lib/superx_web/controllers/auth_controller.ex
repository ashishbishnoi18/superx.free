defmodule SuperXWeb.AuthController do
  @moduledoc """
  The X OAuth2 (PKCE) sign-in flow.

  `request/2` starts a handshake and redirects to X; `callback/2` trades
  the returned code for tokens and either signs the user in or attaches
  the account to an existing session.
  """

  use SuperXWeb, :controller

  require Logger

  alias SuperX.Accounts
  alias SuperX.Accounts.{Connect, OAuthRequest}
  alias SuperXWeb.UserAuth

  @oauth_state_session_key :oauth_state

  @doc "Kicks off the handshake."
  def request(conn, params) do
    if SuperX.X.configured?() do
      current_user = conn.assigns[:current_user]

      {:ok, oauth_request} =
        Accounts.create_oauth_request(%{
          user_id: current_user && current_user.id,
          redirect_to: safe_redirect(params["redirect_to"])
        })

      challenge = OAuthRequest.challenge(oauth_request.code_verifier)

      conn
      |> put_session(@oauth_state_session_key, oauth_request.state)
      |> redirect(external: SuperX.X.authorize_url(oauth_request.state, challenge))
    else
      conn
      |> put_flash(:error, "X sign-in is not configured on this server.")
      |> redirect(to: ~p"/")
    end
  end

  @doc "Handles the redirect back from X."
  def callback(conn, %{"error" => error, "state" => state} = params) do
    if valid_browser_state?(conn, state) do
      _ = Accounts.consume_oauth_request(state)
      Logger.info("X OAuth returned error: #{error} #{inspect(params["error_description"])}")

      conn
      |> delete_session(@oauth_state_session_key)
      |> put_flash(:error, oauth_error_message(error))
      |> redirect(to: ~p"/")
    else
      invalid_state(conn)
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    with true <- valid_browser_state?(conn, state),
         {:ok, request} <- Accounts.consume_oauth_request(state),
         :ok <- authorize_request_session(conn, request),
         {:ok, tokens} <- SuperX.X.exchange_code(code, request.code_verifier),
         {:ok, profile} <- SuperX.X.get_me(tokens.access_token) do
      conn
      |> delete_session(@oauth_state_session_key)
      |> complete(request, profile, tokens)
    else
      false ->
        invalid_state(conn)

      {:error, :invalid_state} ->
        invalid_state(conn)

      {:error, :session_mismatch} ->
        conn
        |> delete_session(@oauth_state_session_key)
        |> put_flash(:error, "That account-link request belongs to another session.")
        |> redirect(to: ~p"/")

      {:error, reason} ->
        Logger.warning("X OAuth callback failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "We couldn't complete sign-in with X. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "That sign-in link was incomplete. Please try again.")
    |> redirect(to: ~p"/")
  end

  # Connecting an extra account to a session that already exists.
  defp complete(conn, %OAuthRequest{user_id: user_id} = request, profile, tokens)
       when not is_nil(user_id) do
    with %{id: ^user_id} <- conn.assigns[:current_user],
         user <- Accounts.get_user_with_context!(user_id),
         result <- Connect.attach(user, profile, tokens) do
      complete_attach(conn, request, profile, result)
    else
      _session_mismatch ->
        conn
        |> put_flash(:error, "That account-link request belongs to another session.")
        |> redirect(to: ~p"/")
    end
  end

  # A fresh sign-in.
  defp complete(conn, request, profile, tokens) do
    case Connect.sign_in(profile, tokens) do
      {:ok, user, _account} ->
        UserAuth.log_in_user(conn, user, request.redirect_to)

      {:error, reason} ->
        Logger.warning("X sign-in failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "We couldn't sign you in. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  defp complete_attach(conn, request, profile, result) do
    case result do
      {:ok, account} ->
        conn
        |> put_flash(:info, "Connected @#{account.handle}.")
        |> redirect(to: request.redirect_to || ~p"/accounts")

      {:error, :already_linked} ->
        conn
        |> put_flash(:error, "@#{profile.handle} is already connected to another account.")
        |> redirect(to: ~p"/accounts")

      {:error, :account_limit_reached} ->
        conn
        |> put_flash(
          :error,
          "This instance's tier allows fewer accounts. Raise SUPERX_DEFAULT_TIER to connect more."
        )
        |> redirect(to: ~p"/accounts")

      {:error, reason} ->
        Logger.warning("Attaching X account failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "We couldn't connect that account.")
        |> redirect(to: ~p"/accounts")
    end
  end

  @doc "Signs the current user out."
  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end

  defp oauth_error_message("access_denied"), do: "Sign-in was cancelled."
  defp oauth_error_message(_), do: "X couldn't complete the sign-in request."

  defp valid_browser_state?(conn, state) when is_binary(state) do
    case get_session(conn, @oauth_state_session_key) do
      expected when is_binary(expected) and byte_size(expected) == byte_size(state) ->
        Plug.Crypto.secure_compare(expected, state)

      _other ->
        false
    end
  end

  defp valid_browser_state?(_conn, _state), do: false

  defp authorize_request_session(_conn, %OAuthRequest{user_id: nil}), do: :ok

  defp authorize_request_session(conn, %OAuthRequest{user_id: user_id}) do
    case conn.assigns[:current_user] do
      %{id: ^user_id} -> :ok
      _other -> {:error, :session_mismatch}
    end
  end

  defp invalid_state(conn) do
    conn
    |> delete_session(@oauth_state_session_key)
    |> put_flash(
      :error,
      "That sign-in link expired or belongs to another browser. Please try again."
    )
    |> redirect(to: ~p"/")
  end

  # Only ever redirect within this app — never to a caller-supplied host.
  defp safe_redirect("/" <> _ = path) do
    uri = URI.parse(path)

    if is_nil(uri.scheme) and is_nil(uri.host) and not String.starts_with?(path, "//") and
         not String.contains?(path, "\\") do
      path
    end
  end

  defp safe_redirect(_), do: nil
end
