defmodule SuperXWeb.ReadyToPostLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Content, Media}

  setup do
    previous = Application.get_env(:superx, Media, [])

    path =
      Path.join(System.tmp_dir!(), "superx-shelf-media-#{System.unique_integer([:positive])}")

    Application.put_env(:superx, Media, path: path)

    on_exit(fn ->
      Application.put_env(:superx, Media, previous)
      File.rm_rf!(path)
    end)

    :ok
  end

  test "keeps a shelf upload when the draft is accepted", %{conn: conn} do
    %{user: user, account: account} = user_fixture()

    {:ok, generation} =
      Content.create_generation(%{
        user_id: user.id,
        x_account_id: account.id,
        segments: [%{"text" => "shelf draft", "media_ids" => []}]
      })

    {:ok, token} = Accounts.create_session(user)
    conn = init_test_session(conn, %{user_token: token})
    {:ok, view, _html} = live(conn, ~p"/ready-to-post")

    form_selector = "#shelf-media-#{generation.id}"
    document = view |> render() |> LazyHTML.from_fragment()
    inputs = LazyHTML.query(document, "#{form_selector} input[type=file]")
    [upload_name] = LazyHTML.attribute(inputs, "name")

    upload =
      file_input(view, form_selector, upload_name, [
        %{
          name: "shelf.png",
          content: <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 0>>,
          type: "image/png"
        }
      ])

    render_upload(upload, "shelf.png")

    view
    |> element("#{form_selector} button[phx-click=accept]")
    |> render_click()

    [post] = Content.list_posts(account, "scheduled")
    assert [%{"media_ids" => [media_id]}] = post.segments
    assert {:ok, _media} = Media.file(media_id)
  end
end
