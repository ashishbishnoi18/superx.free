defmodule SuperX.MediaTest do
  use ExUnit.Case, async: false

  alias SuperX.Media

  setup do
    previous = Application.get_env(:superx, Media, [])
    path = Path.join(System.tmp_dir!(), "superx-media-#{System.unique_integer([:positive])}")
    Application.put_env(:superx, Media, path: path)

    on_exit(fn ->
      Application.put_env(:superx, Media, previous)
      File.rm_rf!(path)
    end)

    %{path: path}
  end

  test "stores recognised image bytes under an opaque key", %{path: path} do
    upload = temporary_file(<<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 0>>)

    assert {:ok, key} = Media.store_upload(%{path: upload})
    assert String.ends_with?(key, ".png")
    assert {:ok, media} = Media.file(key)
    assert media.path == Path.join(path, key)
    assert media.content_type == "image/png"
    assert Media.url(key) == "/uploads/#{key}"
  end

  test "rejects a renamed non-image instead of trusting the browser MIME type" do
    upload = temporary_file("not really an image")

    assert {:error, :unsupported_media} = Media.store_upload(%{path: upload})
  end

  test "never resolves paths outside the configured upload directory" do
    assert {:error, :not_found} = Media.file("../secrets.png")
  end

  defp temporary_file(contents) do
    path = Path.join(System.tmp_dir!(), "superx-upload-#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
