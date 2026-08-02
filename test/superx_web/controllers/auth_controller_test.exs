defmodule SuperXWeb.AuthControllerTest do
  use SuperXWeb.ConnCase, async: false

  import SuperX.Fixtures

  alias SuperX.Accounts
  alias SuperXWeb.UserAuth

  setup do
    previous = Application.get_env(:superx, SuperX.X, [])

    Application.put_env(
      :superx,
      SuperX.X,
      Keyword.merge(previous,
        client_id: "client-id",
        client_secret: "client-secret",
        redirect_uri: "https://superx.test/auth/x/callback"
      )
    )

    on_exit(fn -> Application.put_env(:superx, SuperX.X, previous) end)
    :ok
  end

  test "stores OAuth state in the initiating browser and rejects external redirects", %{
    conn: conn
  } do
    conn = get(conn, ~p"/auth/x?redirect_to=//attacker.example/path")
    state = get_session(conn, :oauth_state)

    assert is_binary(state)
    assert redirected_to(conn, 302) =~ "state=#{URI.encode_www_form(state)}"

    assert {:ok, request} = Accounts.consume_oauth_request(state)
    assert request.redirect_to == nil
  end

  test "does not consume or exchange a callback from another browser", %{conn: conn} do
    {:ok, request} = Accounts.create_oauth_request()
    calls = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(SuperX.X, fn conn ->
      Agent.update(calls, &(&1 + 1))
      Plug.Conn.send_resp(conn, 500, "must not be called")
    end)

    conn =
      conn
      |> init_test_session(%{oauth_state: "another-browser"})
      |> get(~p"/auth/x/callback?code=code&state=#{request.state}")

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "another browser"
    assert Agent.get(calls, & &1) == 0
    assert {:ok, consumed} = Accounts.consume_oauth_request(request.state)
    assert consumed.id == request.id
  end

  test "completes a fresh sign-in for the browser that initiated it", %{conn: conn} do
    {:ok, request} = Accounts.create_oauth_request()

    Req.Test.stub(SuperX.X, fn conn ->
      case conn.request_path do
        "/2/oauth2/token" ->
          json(conn, %{
            "access_token" => "fresh-access",
            "refresh_token" => "fresh-refresh",
            "expires_in" => 7200,
            "scope" => "tweet.read tweet.write"
          })

        "/2/users/me" ->
          json(conn, %{
            "data" => %{
              "id" => "fresh-sign-in-x",
              "username" => "fresh_sign_in",
              "name" => "Fresh Sign In"
            }
          })
      end
    end)

    conn =
      conn
      |> init_test_session(%{oauth_state: request.state})
      |> get(~p"/auth/x/callback?code=code&state=#{request.state}")

    assert redirected_to(conn) == "/welcome"
    assert is_binary(get_session(conn, :user_token))
    assert Accounts.get_x_account_by_x_user_id("fresh-sign-in-x").handle == "fresh_sign_in"
  end

  test "refuses to attach an account when the authenticated user changed", %{conn: conn} do
    %{user: initiator} = user_fixture()
    %{user: other_user} = user_fixture()
    {:ok, request} = Accounts.create_oauth_request(%{user_id: initiator.id})
    {:ok, other_session} = Accounts.create_session(other_user)
    calls = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(SuperX.X, fn conn ->
      Agent.update(calls, &(&1 + 1))

      case conn.request_path do
        "/2/oauth2/token" ->
          json(conn, %{
            "access_token" => "victim-access",
            "refresh_token" => "victim-refresh",
            "expires_in" => 7200,
            "scope" => "tweet.read tweet.write"
          })

        "/2/users/me" ->
          json(conn, %{
            "data" => %{
              "id" => "victim-new-x",
              "username" => "victim_new",
              "name" => "Victim"
            }
          })
      end
    end)

    conn =
      conn
      |> init_test_session(%{user_token: other_session, oauth_state: request.state})
      |> get(~p"/auth/x/callback?code=code&state=#{request.state}")

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "another session"
    assert Agent.get(calls, & &1) == 0
    assert Accounts.get_x_account_by_x_user_id("victim-new-x") == nil
  end

  test "logout disconnects already-mounted LiveView sessions", %{conn: conn} do
    %{user: user} = user_fixture()
    {:ok, token} = Accounts.create_session(user)
    topic = "users_sessions:#{Base.url_encode64(token)}"
    :ok = Phoenix.PubSub.subscribe(SuperX.PubSub, topic)

    conn =
      conn
      |> init_test_session(%{user_token: token, live_socket_id: topic})
      |> UserAuth.log_out_user()

    assert redirected_to(conn) == "/"
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    assert Accounts.get_user_by_session_token(token) == nil
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
