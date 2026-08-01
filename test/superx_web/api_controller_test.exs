defmodule SuperXWeb.ApiControllerTest do
  use SuperXWeb.ConnCase, async: true

  import SuperX.Fixtures

  alias SuperX.{Accounts, Analytics, Content}

  setup do
    %{user: user, account: account} = user_fixture()
    {:ok, api_token, plaintext} = Accounts.create_api_token(user, %{"name" => "Test client"})

    %{user: user, account: account, api_token: api_token, plaintext: plaintext}
  end

  test "requires a valid Bearer credential", %{conn: conn, plaintext: plaintext} do
    assert %{"error" => _message} = conn |> get(~p"/api/queue") |> json_response(401)

    assert %{"error" => _message} =
             conn
             |> recycle()
             |> put_req_header("authorization", "Bearer #{plaintext}changed")
             |> get(~p"/api/queue")
             |> json_response(401)
  end

  test "returns one queue state from the selected account", %{
    conn: conn,
    user: user,
    account: account,
    plaintext: plaintext
  } do
    scheduled_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

    {:ok, post} =
      Content.create_post(user, account, %{
        status: "scheduled",
        scheduled_at: scheduled_at,
        segments: [%{"text" => "Scheduled through the context"}]
      })

    %{user: other_user, account: other_account} = user_fixture()

    {:ok, _other_post} =
      Content.create_post(other_user, other_account, %{
        status: "scheduled",
        scheduled_at: scheduled_at,
        segments: [%{"text" => "Must not leak"}]
      })

    body =
      conn
      |> authorise(plaintext)
      |> get(~p"/api/queue")
      |> json_response(200)

    assert body["account"]["id"] == account.id
    assert body["status"] == "scheduled"
    assert [%{"id" => id, "segments" => [%{"text" => text}]}] = body["posts"]
    assert id == post.id
    assert text == "Scheduled through the context"
  end

  test "returns the shelf with the existing counts", %{
    conn: conn,
    user: user,
    account: account,
    plaintext: plaintext
  } do
    {:ok, generation} =
      Content.create_generation(%{
        user_id: user.id,
        x_account_id: account.id,
        kind: "viral",
        segments: [%{"text" => "Waiting for review"}]
      })

    body =
      conn
      |> authorise(plaintext)
      |> get(~p"/api/shelf")
      |> json_response(200)

    assert body["counts"]["all"] == 1
    assert body["counts"]["viral"] == 1
    assert [%{"id" => id, "kind" => "viral"}] = body["drafts"]
    assert id == generation.id
  end

  test "returns the existing analytics summary for a bounded range", %{
    conn: conn,
    account: account,
    plaintext: plaintext
  } do
    today = Date.utc_today()

    {:ok, _first} =
      Analytics.record_snapshot(account, Date.add(today, -30), %{
        followers: 100,
        posts: 20,
        impressions: 40,
        engagements: 4
      })

    {:ok, _last} =
      Analytics.record_snapshot(account, today, %{
        followers: 112,
        posts: 23,
        impressions: 80,
        engagements: 8
      })

    body =
      conn
      |> authorise(plaintext)
      |> get(~p"/api/analytics?days=30")
      |> json_response(200)

    assert body["days"] == 30
    assert body["summary"]["followers"] == 112
    assert body["summary"]["followers_change"] == 12
    assert body["summary"]["posts"] == 3
    assert body["summary"]["impressions"] == 120
  end

  test "rejects a revoked credential", %{
    conn: conn,
    user: user,
    api_token: api_token,
    plaintext: plaintext
  } do
    {:ok, _revoked} = Accounts.revoke_api_token(user, api_token.id)

    conn = conn |> authorise(plaintext) |> get(~p"/api/analytics")

    assert %{"error" => _message} = json_response(conn, 401)
  end

  defp authorise(conn, plaintext) do
    put_req_header(conn, "authorization", "Bearer #{plaintext}")
  end
end
