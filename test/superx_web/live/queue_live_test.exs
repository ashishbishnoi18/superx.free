defmodule SuperXWeb.QueueLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, AI, Billing, Content, Media}

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
    assert {:ok, _media} = Media.file(user, media_id)
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
    assert Content.get_generation(user, account, generation.id).status == "used"
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

  test "automation settings persist with the draft and round-trip on edit", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue")

    view |> element("button[phx-click=compose]") |> render_click()
    refute has_element?(view, "#automations-panel")

    view |> element("#automations-toggle") |> render_click()

    view
    |> element("#post-composer textarea[id^='post-segment-']")
    |> render_blur(%{"index" => "0", "value" => "A post with automations"})

    view
    |> element("#auto-retweet-hours")
    |> render_blur(%{"field" => "auto_retweet_hours", "value" => "12"})

    view
    |> element("#auto-retweet-undo-hours")
    |> render_blur(%{"field" => "auto_retweet_undo_hours", "value" => "6"})

    view
    |> element("#auto-plug-likes")
    |> render_blur(%{"field" => "auto_plug_likes", "value" => "50"})

    view
    |> element("#auto-plug-text")
    |> render_blur(%{"field" => "auto_plug_text", "value" => "If you liked this, try the course"})

    view
    |> element("#auto-delete-min-views")
    |> render_blur(%{"field" => "auto_delete_min_views", "value" => "1000"})

    view
    |> element("#auto-delete-hours")
    |> render_blur(%{"field" => "auto_delete_hours", "value" => "48"})

    view |> element("#save-post-draft") |> render_click()

    [post] = Content.list_posts(account, "draft")
    assert post.auto_retweet_hours == 12
    assert post.auto_retweet_undo_hours == 6
    assert post.auto_plug_likes == 50
    assert post.auto_plug_text == "If you liked this, try the course"
    assert post.auto_delete_min_views == 1000
    assert post.auto_delete_hours == 48

    {:ok, edit_view, _html} = live(conn_for(conn, user), ~p"/queue/#{post.id}")

    # A post with settings opens the panel so they are not invisible.
    assert has_element?(edit_view, "#automations-panel")
    assert has_element?(edit_view, "#auto-retweet-hours[value='12']")
    assert has_element?(edit_view, "#auto-retweet-undo-hours[value='6']")
    assert has_element?(edit_view, "#auto-plug-text", "If you liked this, try the course")

    edit_view
    |> element("#auto-retweet-hours")
    |> render_blur(%{"field" => "auto_retweet_hours", "value" => "9"})

    edit_view |> element("#save-post-draft") |> render_click()

    assert Content.get_post(user, account, post.id).auto_retweet_hours == 9
  end

  test "automations round-trip when re-queuing a scheduled post", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    opening = Content.next_open_slot_at(account, user)

    {:ok, post} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "Queued with automations"}],
        status: "draft",
        auto_retweet_hours: 4,
        auto_plug_likes: 20,
        auto_plug_text: "More where that came from"
      })

    {:ok, scheduled} = Content.schedule_post(post, at: opening)

    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue/#{scheduled.id}")

    assert has_element?(view, "#auto-retweet-hours[value='4']")
    assert has_element?(view, "#auto-plug-likes[value='20']")

    view
    |> element("#auto-retweet-hours")
    |> render_blur(%{"field" => "auto_retweet_hours", "value" => "9"})

    view |> element("#add-post-to-queue") |> render_click()

    reloaded = Content.get_post(user, account, post.id)
    assert reloaded.status == "scheduled"
    assert reloaded.auto_retweet_hours == 9
    assert reloaded.auto_plug_likes == 20
    assert reloaded.auto_plug_text == "More where that came from"
  end

  test "typing autosaves one draft that later blurs keep updating", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue")

    view |> element("button[phx-click=compose]") |> render_click()
    assert has_element?(view, "#emoji-picker-button")

    view
    |> element("#post-composer textarea")
    |> render_blur(%{"index" => "0", "value" => "First words"})

    [draft] = Content.list_posts(account, "draft")
    assert [%{"text" => "First words"}] = draft.segments
    assert has_element?(view, "#composer-save-state", "Saved")

    view
    |> element("#post-composer textarea")
    |> render_blur(%{"index" => "0", "value" => "First words, extended"})

    assert [updated] = Content.list_posts(account, "draft")
    assert updated.id == draft.id
    assert [%{"text" => "First words, extended"}] = updated.segments
  end

  test "blurring an empty composer does not create a draft", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue")

    view |> element("button[phx-click=compose]") |> render_click()

    view
    |> element("#post-composer textarea")
    |> render_blur(%{"index" => "0", "value" => ""})

    assert Content.list_posts(account, "draft") == []
  end

  test "closing an emptied autosaved draft does not leave it on the shelf", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue")

    view |> element("button[phx-click=compose]") |> render_click()

    view
    |> element("#post-composer textarea")
    |> render_blur(%{"index" => "0", "value" => "Momentary thought"})

    assert [_draft] = Content.list_posts(account, "draft")

    view
    |> element("#post-composer textarea")
    |> render_blur(%{"index" => "0", "value" => ""})

    view |> element("button[phx-click=close_composer]") |> render_click()

    assert Content.list_posts(account, "draft") == []
  end

  test "posted posts show what their automations did", %{conn: conn} do
    %{user: user, account: account} = user_fixture()

    {:ok, deleted} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "Underperformed"}],
        status: "draft",
        auto_delete_min_views: 100,
        auto_delete_hours: 24
      })

    {:ok, deleted} = Content.mark_published(deleted, ["x-deleted"])

    {:ok, _} =
      Content.update_automation_state(deleted, %{"deleted_at" => "2026-08-01T10:00:00Z"})

    {:ok, failed} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "Repost bounced"}],
        status: "draft",
        auto_retweet_hours: 5
      })

    {:ok, failed} = Content.mark_published(failed, ["x-failed"])

    {:ok, _} =
      Content.update_automation_state(failed, %{"failed_retweet" => "rate limited by X"})

    {:ok, active} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "Waiting on likes"}],
        status: "draft",
        auto_plug_likes: 10,
        auto_plug_text: "Plug text"
      })

    {:ok, active} = Content.mark_published(active, ["x-active"])

    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue?tab=posted")

    assert has_element?(view, "#post-#{deleted.id}-automation-deleted", "deleted by automation")

    assert has_element?(
             view,
             "#post-#{failed.id}-automation-failed[title*='rate limited by X']"
           )

    assert has_element?(view, "#post-#{active.id}-automations-active")
  end

  test "improve stays hidden without an LLM key", %{conn: conn} do
    %{user: user} = user_fixture()
    without_ai_key()

    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue")
    view |> element("button[phx-click=compose]") |> render_click()

    view
    |> element("#post-composer textarea")
    |> render_blur(%{"index" => "0", "value" => "words to improve"})

    refute has_element?(view, "#improve-with-ai")
  end

  test "improve rewrites the composer's segments but leaves saving to the writer", %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    with_ai_key()

    stub_improve(fn conn, request ->
      assert request["messages"] |> List.first() |> Map.fetch!("content") =~
               "rough words that need work"

      json_reply(conn, 200, %{
        "content" => [
          %{"type" => "tool_use", "input" => %{"segments" => ["tighter words that work"]}}
        ]
      })
    end)

    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue")
    view |> element("button[phx-click=compose]") |> render_click()

    view
    |> element("#post-composer textarea")
    |> render_blur(%{"index" => "0", "value" => "rough words that need work"})

    assert has_element?(view, "#improve-with-ai")

    before = Billing.credit_balance(user)
    view |> element("#improve-with-ai") |> render_click()

    assert_receive {:ai_call, task_pid, _request}
    ref = Process.monitor(task_pid)
    send(task_pid, :release_ai)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 2000

    assert has_element?(view, "#post-composer textarea", "tighter words that work")
    assert has_element?(view, "#flash-info", "Improved — review before saving.")
    assert Billing.credit_balance(user) == before - 1

    # The autosaved draft still holds the original words: saving the rewrite
    # is the writer's explicit decision.
    [draft] = Content.list_posts(account, "draft")
    assert [%{"text" => "rough words that need work"}] = draft.segments
  end

  test "a failed improve refunds the credit and keeps the draft", %{conn: conn} do
    %{user: user} = user_fixture()
    with_ai_key()

    stub_improve(fn conn, _request ->
      json_reply(conn, 400, %{"error" => "bad request"})
    end)

    {:ok, view, _html} = live(conn_for(conn, user), ~p"/queue")
    view |> element("button[phx-click=compose]") |> render_click()

    view
    |> element("#post-composer textarea")
    |> render_blur(%{"index" => "0", "value" => "words to improve"})

    before = Billing.credit_balance(user)
    view |> element("#improve-with-ai") |> render_click()

    assert_receive {:ai_call, task_pid, _request}
    ref = Process.monitor(task_pid)
    send(task_pid, :release_ai)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 2000

    assert has_element?(view, "#flash-error", "Couldn't improve the draft just now.")
    assert has_element?(view, "#post-composer textarea", "words to improve")
    assert Billing.credit_balance(user) == before
  end

  # The improve call runs in a task, outside the test process. The stub
  # blocks on a release from the test so the task is still alive to monitor
  # — without it the task can finish before the test finds it.
  defp stub_improve(respond) do
    Req.Test.set_req_test_to_shared()
    test_pid = self()

    Req.Test.stub(AI, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:ai_call, self(), Jason.decode!(raw)})

      receive do
        :release_ai -> respond.(conn, Jason.decode!(raw))
      after
        5_000 -> raise "test never released the stubbed AI call"
      end
    end)
  end

  defp json_reply(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp without_ai_key do
    previous = Application.get_env(:superx, AI, [])
    Application.put_env(:superx, AI, Keyword.put(previous, :api_key, nil))
    on_exit(fn -> Application.put_env(:superx, AI, previous) end)
  end

  defp with_ai_key do
    previous = Application.get_env(:superx, AI, [])

    Application.put_env(
      :superx,
      AI,
      Keyword.merge(previous, api_key: "test-key", writer_model: "test-model")
    )

    on_exit(fn -> Application.put_env(:superx, AI, previous) end)
  end

  defp conn_for(conn, user) do
    {:ok, token} = Accounts.create_session(user)
    init_test_session(conn, %{user_token: token})
  end
end
