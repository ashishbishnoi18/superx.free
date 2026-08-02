defmodule SuperX.MediaTest do
  use SuperX.DataCase, async: false

  import SuperX.Fixtures
  alias SuperX.Media

  setup do
    previous = Application.get_env(:superx, Media, [])
    path = Path.join(System.tmp_dir!(), "superx-media-#{System.unique_integer([:positive])}")
    Application.put_env(:superx, Media, path: path)

    on_exit(fn ->
      Application.put_env(:superx, Media, previous)
      File.rm_rf!(path)
    end)

    Map.put(user_fixture(), :path, path)
  end

  test "stores recognised image bytes under an opaque key", %{
    path: path,
    user: user,
    account: account
  } do
    upload = temporary_file(<<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 0>>)

    assert {:ok, key} = Media.store_upload(user, account, %{path: upload})
    assert String.ends_with?(key, ".png")
    assert {:ok, media} = Media.file(user, key)
    assert media.path == Path.join(path, key)
    assert media.content_type == "image/png"
    assert Media.url(key) == "/uploads/#{key}"
  end

  test "rejects a renamed non-image instead of trusting the browser MIME type", %{
    user: user,
    account: account
  } do
    upload = temporary_file("not really an image")

    assert {:error, :unsupported_media} = Media.store_upload(user, account, %{path: upload})
  end

  test "never resolves paths outside the configured upload directory", %{user: user} do
    assert {:error, :not_found} = Media.file(user, "../secrets.png")
  end

  test "does not disclose another user's upload", %{user: owner, account: account} do
    upload = temporary_file(<<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 0>>)
    assert {:ok, key} = Media.store_upload(owner, account, %{path: upload})

    %{user: other_user} = user_fixture()
    assert {:error, :not_found} = Media.file(other_user, key)
  end

  defp temporary_file(contents) do
    path = Path.join(System.tmp_dir!(), "superx-upload-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
