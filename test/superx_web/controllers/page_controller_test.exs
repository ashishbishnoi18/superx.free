defmodule SuperXWeb.PageControllerTest do
  use SuperXWeb.ConnCase, async: true

  import SuperX.Fixtures

  test "renders the marketing page for signed-out visitors", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Grow on 𝕏 without"
    assert html =~ "Writes in your voice"
  end

  test "explains what's missing when X sign-in isn't configured", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    # The test environment has no X credentials, so the sign-in button is
    # replaced by setup guidance rather than a dead link.
    assert html =~ "X sign-in isn't configured yet"
    refute html =~ ~s(href="/auth/x")
  end

  describe "where a signed-in user lands" do
    test "a connected but unconfigured account goes to setup", %{conn: conn} do
      %{user: user} = user_fixture()
      {:ok, token} = SuperX.Accounts.create_session(user)

      conn = conn |> init_test_session(%{user_token: token}) |> get(~p"/")

      assert redirected_to(conn) == ~p"/welcome"
    end

    test "a set-up account goes to Home", %{conn: conn} do
      %{user: user} = user_fixture()

      {:ok, user} =
        SuperX.Accounts.update_user(user, %{
          onboarding_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, token} = SuperX.Accounts.create_session(user)

      conn = conn |> init_test_session(%{user_token: token}) |> get(~p"/")

      assert redirected_to(conn) == ~p"/home"
    end
  end
end
