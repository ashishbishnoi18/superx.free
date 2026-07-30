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

      redirect(conn, external: SuperX.X.authorize_url(oauth_request.state, challenge))
    else
      conn
      |> put_flash(:error, "X sign-in is not configured on this server.")
      |> redirect(to: ~p"/")
    end
  end

  @doc "Handles the redirect back from X."
  def callback(conn, %{"error" => error} = params) do
    # The user pressed Cancel, or X refused the request outright.
    Logger.info("X OAuth returned error: #{error} #{inspect(params["error_description"])}")

    conn
    |> put_flash(:error, oauth_error_message(error))
    |> redirect(to: ~p"/")
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    with {:ok, request} <- Accounts.consume_oauth_request(state),
         {:ok, tokens} <- SuperX.X.exchange_code(code, request.code_verifier),
         {:ok, profile} <- SuperX.X.get_me(tokens.access_token) do
      complete(conn, request, profile, tokens)
    else
      {:error, :invalid_state} ->
        # Either a replayed callback or one that sat idle past the TTL.
        conn
        |> put_flash(:error, "That sign-in link expired. Please try again.")
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
    user = Accounts.get_user_with_context!(user_id)

    case Connect.attach(user, profile, tokens) do
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
        |> put_flash(:error, "Your plan doesn't include another connected account.")
        |> redirect(to: ~p"/upgrade")

      {:error, reason} ->
        Logger.warning("Attaching X account failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "We couldn't connect that account.")
        |> redirect(to: ~p"/accounts")
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

  @doc "Signs the current user out."
  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end

  defp oauth_error_message("access_denied"), do: "Sign-in was cancelled."
  defp oauth_error_message(_), do: "X couldn't complete the sign-in request."

  # Only ever redirect within this app — never to a caller-supplied host.
  defp safe_redirect("/" <> _ = path), do: path
  defp safe_redirect(_), do: nil
end
