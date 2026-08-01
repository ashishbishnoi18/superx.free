defmodule SuperXWeb.ApiControllerTest do
  use SuperXWeb.ConnCase, async: true

  import SuperX.Fixtures

  alias SuperX.{Accounts, Analytics, Billing, Content, Repo}
  alias SuperX.Billing.Plan
  alias SuperX.Content.Post

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

  test "limits authenticated requests with the standard headers", %{plaintext: plaintext} do
    limit = Plan.limit("free", :api_requests_minute)

    Enum.each((limit - 1)..0//-1, fn remaining ->
      conn = build_conn() |> authorise(plaintext) |> get(~p"/api/analytics")

      assert conn.status == 200
      assert get_resp_header(conn, "ratelimit-limit") == [Integer.to_string(limit)]
      assert get_resp_header(conn, "ratelimit-remaining") == [Integer.to_string(remaining)]

      assert [reset] = get_resp_header(conn, "ratelimit-reset")
      assert String.to_integer(reset) in 1..60
    end)

    conn = build_conn() |> authorise(plaintext) |> get(~p"/api/analytics")

    assert %{"error" => _message} = json_response(conn, 429)
    assert get_resp_header(conn, "ratelimit-limit") == [Integer.to_string(limit)]
    assert get_resp_header(conn, "ratelimit-remaining") == ["0"]
    assert get_resp_header(conn, "retry-after") == get_resp_header(conn, "ratelimit-reset")
  end

  test "uses the authenticated user's plan limit", %{plaintext: free_plaintext} do
    %{user: pro_user} = user_fixture()
    {:ok, _subscription} = Billing.upsert_subscription(pro_user, %{tier: "pro", status: "active"})
    {:ok, _token, pro_plaintext} = Accounts.create_api_token(pro_user, %{"name" => "Pro client"})

    free_conn = build_conn() |> authorise(free_plaintext) |> get(~p"/api/analytics")
    pro_conn = build_conn() |> authorise(pro_plaintext) |> get(~p"/api/analytics")

    assert get_resp_header(free_conn, "ratelimit-limit") == [
             Plan.limit("free", :api_requests_minute) |> Integer.to_string()
           ]

    assert get_resp_header(pro_conn, "ratelimit-limit") == [
             Plan.limit("pro", :api_requests_minute) |> Integer.to_string()
           ]

    refute get_resp_header(free_conn, "ratelimit-limit") ==
             get_resp_header(pro_conn, "ratelimit-limit")
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

  test "creates only drafts even when a client asks for a published post", %{
    conn: conn,
    plaintext: plaintext
  } do
    body =
      conn
      |> authorise(plaintext)
      |> post(~p"/api/posts", %{
        "segments" => [%{"text" => "Approved, but not published"}],
        "status" => "posted",
        "published_at" => DateTime.utc_now()
      })
      |> json_response(201)

    assert %{"id" => id, "status" => "draft", "published_at" => nil} = body["post"]
    assert Repo.get!(Post, id).status == "draft"
  end

  test "returns composer validation messages as JSON", %{conn: conn, plaintext: plaintext} do
    body =
      conn
      |> authorise(plaintext)
      |> post(~p"/api/posts", %{
        "segments" => [%{"text" => String.duplicate("x", 281)}]
      })
      |> json_response(422)

    assert body["errors"]["segments"] == ["post 1 is over 280 characters"]
  end

  test "schedules owned drafts into the next opening or an explicit future time", %{
    conn: conn,
    user: user,
    account: account,
    plaintext: plaintext
  } do
    next_opening = Content.next_open_slot_at(account, user)

    {:ok, next_draft} =
      Content.create_post(user, account, %{
        status: "draft",
        segments: [%{"text" => "Use the recurring schedule"}]
      })

    next_body =
      conn
      |> authorise(plaintext)
      |> post(~p"/api/posts/#{next_draft.id}/schedule")
      |> json_response(200)

    assert next_body["post"]["status"] == "scheduled"
    assert next_body["post"]["scheduled_at"] == DateTime.to_iso8601(next_opening)

    explicit_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

    {:ok, explicit_draft} =
      Content.create_post(user, account, %{
        status: "draft",
        segments: [%{"text" => "Use the requested time"}]
      })

    explicit_body =
      conn
      |> recycle()
      |> authorise(plaintext)
      |> post(~p"/api/posts/#{explicit_draft.id}/schedule", %{
        "at" => DateTime.to_iso8601(explicit_at)
      })
      |> json_response(200)

    assert explicit_body["post"]["status"] == "scheduled"
    assert explicit_body["post"]["scheduled_at"] == DateTime.to_iso8601(explicit_at)
  end

  test "cannot delete a post belonging to another user", %{
    conn: conn,
    plaintext: plaintext
  } do
    %{user: other_user, account: other_account} = user_fixture()

    {:ok, other_post} =
      Content.create_post(other_user, other_account, %{
        status: "draft",
        segments: [%{"text" => "Not the caller's post"}]
      })

    body =
      conn
      |> authorise(plaintext)
      |> delete(~p"/api/posts/#{other_post.id}")
      |> json_response(404)

    assert %{"error" => _message} = body
    assert Repo.get!(Post, other_post.id)
  end

  test "deletes an owned post from the selected account", %{
    conn: conn,
    user: user,
    account: account,
    plaintext: plaintext
  } do
    {:ok, post} =
      Content.create_post(user, account, %{
        status: "draft",
        segments: [%{"text" => "Delete this local draft"}]
      })

    response = conn |> authorise(plaintext) |> delete(~p"/api/posts/#{post.id}")

    assert response.status == 204
    assert Repo.get(Post, post.id) == nil
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
