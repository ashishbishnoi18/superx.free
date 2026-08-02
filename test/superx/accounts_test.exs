defmodule SuperX.AccountsTest do
  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.Accounts
  alias SuperX.Accounts.{ApiToken, XAccount}
  alias SuperX.Content
  alias SuperX.Repo

  describe "appearance" do
    test "persists recognised themes and refuses unknown values" do
      %{user: user} = user_fixture()

      assert {:ok, user} = Accounts.update_theme(user, "system")
      assert Accounts.theme(user) == "system"

      assert {:error, :invalid_theme} = Accounts.update_theme(user, "sepia")
      assert Accounts.get_user(user.id) |> Accounts.theme() == "system"
    end
  end

  describe "API tokens" do
    test "stores only a prefix and hash, then rejects a changed secret" do
      %{user: user} = user_fixture()

      assert {:ok, api_token, plaintext} =
               Accounts.create_api_token(user, %{"name" => "Reporting"})

      assert String.starts_with?(plaintext, api_token.token_prefix <> ".")
      assert byte_size(api_token.token_hash) == 32

      stored = Repo.get!(ApiToken, api_token.id)
      assert stored.token_prefix == api_token.token_prefix
      assert stored.token_hash == api_token.token_hash
      refute stored.token_hash == plaintext

      assert Accounts.get_user_by_api_token(plaintext).id == user.id
      assert Accounts.get_user_by_api_token(plaintext <> "changed") == nil
    end

    test "only the owner can revoke a token and revoked tokens stop authenticating" do
      %{user: owner} = user_fixture()
      %{user: other_user} = user_fixture()
      {:ok, api_token, plaintext} = Accounts.create_api_token(owner, %{"name" => "CLI"})

      assert {:error, :not_found} = Accounts.revoke_api_token(other_user, api_token.id)
      assert Accounts.get_user_by_api_token(plaintext).id == owner.id

      assert {:ok, revoked} = Accounts.revoke_api_token(owner, api_token.id)
      assert %DateTime{} = revoked.revoked_at
      assert Accounts.get_user_by_api_token(plaintext) == nil
    end

    test "requires a name before minting secret material into the database" do
      %{user: user} = user_fixture()

      assert {:error, changeset} = Accounts.create_api_token(user, %{"name" => ""})
      assert "can't be blank" in errors_on(changeset).name
      assert Accounts.list_api_tokens(user) == []
    end
  end

  describe "disconnect_x_account/2" do
    test "revokes both credentials, cancels scheduled work, and retains history" do
      %{user: user, account: account} = user_fixture()

      {:ok, draft} =
        Content.create_post(user, account, %{
          segments: [%{"text" => "keep this draft"}],
          status: "draft"
        })

      {:ok, scheduled_source} =
        Content.create_post(user, account, %{
          segments: [%{"text" => "cancel this post"}],
          status: "draft"
        })

      {:ok, scheduled} = Content.schedule_post(scheduled_source)
      calls = start_supervised!({Agent, fn -> [] end})

      Req.Test.stub(SuperX.X, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        Agent.update(calls, &[params["token_type_hint"] | &1])
        Plug.Conn.send_resp(conn, 200, ~s({"revoked":true}))
      end)

      assert {:ok, _changes} = Accounts.disconnect_x_account(user, account.id)
      assert Enum.sort(Agent.get(calls, & &1)) == ["access_token", "refresh_token"]

      disconnected = Repo.get!(XAccount, account.id)
      assert %DateTime{} = disconnected.disconnected_at
      assert disconnected.access_token == nil
      assert disconnected.refresh_token == nil
      assert Accounts.list_x_accounts(user) == []
      assert Accounts.current_x_account(user) == nil

      assert Repo.get!(SuperX.Content.Post, draft.id).status == "draft"
      assert Repo.get!(SuperX.Content.Post, scheduled.id).status == "cancelled"
    end

    test "takes the stored chat identity with it" do
      # It is a private key for an account we no longer act as, and it would
      # otherwise outlive the OAuth tokens revoked in the same call.
      %{user: user, account: account} = user_fixture()

      {:ok, _identity} =
        %SuperX.XChat.Identity{x_account_id: account.id}
        |> Ecto.Changeset.change(
          private_key: "private-key-material",
          key_version: "7",
          registration: %{"version" => "7"}
        )
        |> Repo.insert()

      Req.Test.stub(SuperX.X, fn conn ->
        Plug.Conn.send_resp(conn, 200, ~s({"revoked":true}))
      end)

      assert {:ok, _changes} = Accounts.disconnect_x_account(user, account.id)
      assert Repo.aggregate(SuperX.XChat.Identity, :count) == 0
    end

    test "keeps credentials locally when X revocation fails" do
      %{user: user, account: account} = user_fixture()

      Req.Test.stub(SuperX.X, fn conn ->
        Plug.Conn.send_resp(conn, 400, ~s({"error":"rejected"}))
      end)

      assert {:error, {:revocation_failed, "access_token", _reason}} =
               Accounts.disconnect_x_account(user, account.id)

      connected = Repo.get!(XAccount, account.id)
      assert connected.disconnected_at == nil
      assert connected.access_token == "access-token"
      assert connected.refresh_token == "refresh-token"
    end
  end
end
