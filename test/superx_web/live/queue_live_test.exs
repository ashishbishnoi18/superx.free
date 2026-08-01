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

  test "shows occupied slots and openings together", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    opening = Content.next_open_slot_at(account, user)

    {:ok, post} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "Already queued"}],
        status: "draft"
      })

    {:ok, _post} = Content.schedule_post(post, at: opening)
    next_opening = Content.next_open_slot_at(account, user)

    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue")

    assert has_element?(view, "#queue-upcoming-slots")

    assert has_element?(
             view,
             "#queue-slot-#{DateTime.to_unix(opening)}[data-slot-state=scheduled]"
           )

    assert has_element?(view, "#write-slot-#{DateTime.to_unix(next_opening)}")
  end

  test "writing from an opening schedules the post into that exact slot", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    opening = Content.next_open_slot_at(account, user)
    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue")

    view
    |> element("#write-slot-#{DateTime.to_unix(opening)}")
    |> render_click()

    view
    |> element("#post-composer textarea")
    |> render_blur(%{"index" => "0", "value" => "Written for this opening"})

    view |> element("#add-post-to-queue") |> render_click()

    assert [scheduled] = Content.list_posts(account, "scheduled")
    assert scheduled.scheduled_at == opening
  end

  test "a ready draft can fill a chosen opening", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    opening = Content.next_open_slot_at(account, user)

    {:ok, generation} =
      Content.create_generation(%{
        user_id: user.id,
        x_account_id: account.id,
        segments: [%{"text" => "Waiting on the shelf"}]
      })

    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue")

    view
    |> element("#ready-slot-#{DateTime.to_unix(opening)}")
    |> render_click()

    assert has_element?(view, "#ready-choice-#{generation.id}")

    view
    |> element("#ready-choice-#{generation.id} button")
    |> render_click()

    assert [scheduled] = Content.list_posts(account, "scheduled")
    assert scheduled.scheduled_at == opening
    assert Content.get_generation(user, generation.id).status == "used"
  end

  test "shows a schedule action when there are no recurring slots", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    Enum.each(Content.list_slots(account), &Content.delete_slot(account, &1.id))

    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue")

    assert has_element?(view, "#queue-no-schedule a[href='/settings']")
  end

  defp conn_for(conn, user) do
    {:ok, token} = Accounts.create_session(user)
    init_test_session(conn, %{user_token: token})
  end
end
