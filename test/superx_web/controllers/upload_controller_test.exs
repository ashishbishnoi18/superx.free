defmodule SuperXWeb.UploadControllerTest do
  use SuperXWeb.ConnCase, async: false

  import SuperX.Fixtures

  alias SuperX.{Accounts, Media}

  setup do
    previous = Application.get_env(:superx, Media, [])

    path =
      Path.join(
        System.tmp_dir!(),
        "superx-controller-media-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:superx, Media, path: path)

    on_exit(fn ->
      Application.put_env(:superx, Media, previous)
      File.rm_rf!(path)
    end)

    :ok
  end

  test "returns another user's opaque media key as not found", %{conn: conn} do
    %{user: owner, account: owner_account} = user_fixture()
    %{user: other_user} = user_fixture()
    temporary = temporary_png()
    assert {:ok, key} = Media.store_upload(owner, owner_account, %{path: temporary})
    {:ok, other_session} = Accounts.create_session(other_user)

    response =
      conn
      |> init_test_session(%{user_token: other_session})
      |> get(~p"/uploads/#{key}")

    assert response(response, 404) == "Not found"
  end

  test "serves media to its owner", %{conn: conn} do
    %{user: owner, account: owner_account} = user_fixture()
    temporary = temporary_png()
    assert {:ok, key} = Media.store_upload(owner, owner_account, %{path: temporary})
    {:ok, owner_session} = Accounts.create_session(owner)

    response =
      conn
      |> init_test_session(%{user_token: owner_session})
      |> get(~p"/uploads/#{key}")

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/png; charset=utf-8"]
  end

  defp temporary_png do
    path =
      Path.join(
        System.tmp_dir!(),
        "superx-controller-upload-#{System.unique_integer([:positive])}"
      )

    File.write!(path, <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 0>>)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
