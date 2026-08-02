defmodule SuperXWeb.ReadyToPostLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{AI, Accounts, Content, Media, Workers}

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
    assert {:ok, _media} = Media.file(user, media_id)
  end

  test "offers the product filter created by product workers", %{conn: conn} do
    previous_ai = Application.get_env(:superx, AI, [])

    Application.put_env(
      :superx,
      AI,
      Keyword.merge(previous_ai, api_key: "test-key", base_url: "https://api.anthropic.test")
    )

    on_exit(fn -> Application.put_env(:superx, AI, previous_ai) end)

    %{user: user, account: account} = user_fixture()

    {:ok, generation} =
      Content.create_generation(%{
        user_id: user.id,
        x_account_id: account.id,
        kind: "products",
        segments: [%{"text" => "A product draft", "media_ids" => []}]
      })

    {:ok, token} = Accounts.create_session(user)
    conn = init_test_session(conn, %{user_token: token})
    {:ok, view, _html} = live(conn, ~p"/ready-to-post")

    assert has_element?(view, "#write-another")
    assert has_element?(view, "a[href='/ready-to-post?kind=products']", "Products")

    view
    |> element("a[href='/ready-to-post?kind=products']")
    |> render_click()

    assert has_element?(view, "#shelf-media-#{generation.id}")

    # A shelf filter must not masquerade as a writing strategy. The direct
    # writer has no product brief; product drafts come from product workers.
    refute has_element?(view, "[phx-click='generate']")
  end

  test "does not promise an overnight refill after an on-demand worker disables it", %{
    conn: conn
  } do
    %{user: user, account: account} = user_fixture()
    {:ok, voice} = Content.get_or_create_voice_profile(account)
    {:ok, _voice} = Content.update_voice_profile(voice, %{about: "I build software."})

    {:ok, _worker} =
      Workers.create_content_worker(user, account, %{
        name: "Manual product notes",
        topic_source: "products",
        product_context: "A private analytics workspace for small teams.",
        batch_size: 3,
        cadence: nil
      })

    {:ok, token} = Accounts.create_session(user)
    conn = init_test_session(conn, %{user_token: token})
    {:ok, view, _html} = live(conn, ~p"/ready-to-post")

    assert has_element?(
             view,
             "#shelf-manual-workers-empty",
             "No drafts waiting. Your workers only run when you press Run now."
           )

    assert has_element?(view, "#run-a-worker[href='/workers']")
  end
end
