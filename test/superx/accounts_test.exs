defmodule SuperX.AccountsTest do
  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.Accounts
  alias SuperX.Accounts.ApiToken
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
end
