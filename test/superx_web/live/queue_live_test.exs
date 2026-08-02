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

  test "keeps a post visible in its slot while X is publishing it", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    opening = Content.next_open_slot_at(account, user)

    {:ok, post} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "On its way to X"}],
        status: "draft"
      })

    {:ok, scheduled} = Content.schedule_post(post, at: opening)
    {:ok, _publishing} = Content.claim_for_publishing(scheduled.id)

    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue")

    assert has_element?(
             view,
             "#queue-slot-#{DateTime.to_unix(opening)}[data-slot-state=publishing]",
             "On its way to X"
           )

    assert has_element?(view, "a[href='/queue?tab=scheduled'] span", "1")
    refute has_element?(view, "#delete-post-#{scheduled.id}")
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

  test "rechecks an opening before starting work from a stale page", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    opening = Content.next_open_slot_at(account, user)
    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue")

    {:ok, blocker} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "Claimed in another tab"}],
        status: "draft"
      })

    {:ok, _scheduled} = Content.schedule_post(blocker, at: opening)

    view
    |> element("#write-slot-#{DateTime.to_unix(opening)}")
    |> render_click()

    refute has_element?(view, "#post-composer")
    assert has_element?(view, "#flash-error", "That opening was filled while you were choosing.")
  end

  test "a failed post shows X's reason and can be edited with its text intact", %{conn: conn} do
    %{user: user, account: account} = user_fixture()

    {:ok, post} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "Keep this text"}],
        status: "draft"
      })

    {:ok, _failed} = Content.mark_failed(post, "X returned 400: duplicate content")
    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue?tab=failed")

    assert has_element?(
             view,
             "#post-#{post.id}-error",
             "X returned 400: duplicate content"
           )

    assert has_element?(view, "#edit-post-#{post.id}")

    view |> element("#edit-post-#{post.id}") |> render_click()

    assert has_element?(view, "#post-composer textarea", "Keep this text")
  end

  test "a partially published thread cannot be retried as a duplicate", %{conn: conn} do
    %{user: user, account: account} = user_fixture()

    {:ok, post} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "Already live"}, %{"text" => "Did not publish"}],
        status: "draft"
      })

    partial =
      post
      |> Ecto.Changeset.change(
        status: "failed",
        error: "Published 1 of 2 posts, then failed",
        failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        x_post_ids: ["first-live-id"]
      )
      |> SuperX.Repo.update!()

    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue?tab=failed")

    refute has_element?(view, "#retry-post-#{partial.id}")

    assert has_element?(
             view,
             "#view-published-part-#{partial.id}[href='https://x.com/i/status/first-live-id']"
           )

    {:ok, direct_view, _html} = live(conn_for(conn, user), ~p"/queue/#{partial.id}")
    refute has_element?(direct_view, "#post-composer")
  end

  defp conn_for(conn, user) do
    {:ok, token} = Accounts.create_session(user)
    init_test_session(conn, %{user_token: token})
  end
end
