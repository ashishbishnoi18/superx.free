defmodule SuperXWeb.QueueLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Content, Media}

  setup do
    previous = Application.get_env(:superx, Media, [])
    path = Path.join(System.tmp_dir!(), "superx-live-media-#{System.unique_integer([:positive])}")
    Application.put_env(:superx, Media, path: path)

    on_exit(fn ->
      Application.put_env(:superx, Media, previous)
      File.rm_rf!(path)
    end)

    :ok
  end

  test "stores an upload on the segment that owns its file input", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, token} = Accounts.create_session(user)
    conn = init_test_session(conn, %{user_token: token})

    {:ok, view, _html} = live(conn, ~p"/queue")
    view |> element("button[phx-click=compose]") |> render_click()

    document = view |> render() |> LazyHTML.from_fragment()
    inputs = LazyHTML.query(document, "#post-composer input[type=file]")
    [upload_name] = LazyHTML.attribute(inputs, "name")

    upload =
      file_input(view, "#post-composer", upload_name, [
        %{
          name: "proof.png",
          content: <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 0>>,
          type: "image/png"
        }
      ])

    render_upload(upload, "proof.png")
    view |> element("#save-post-draft") |> render_click()

    [post] = Content.list_posts(account, "draft")
    assert [%{"media_ids" => [media_id]}] = post.segments
    assert {:ok, _media} = Media.file(media_id)
  end
end
