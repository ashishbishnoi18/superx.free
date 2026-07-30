defmodule SuperX.ContentTest do
  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.{Accounts, Content}

  setup do
    user_fixture()
  end

  describe "post validation" do
    test "rejects a segment over the character limit", %{user: user, account: account} do
      long = String.duplicate("a", 281)

      assert {:error, changeset} =
               Content.create_post(user, account, %{
                 segments: [%{"text" => long}],
                 status: "draft"
               })

      assert "post 1 is over 280 characters" in errors_on(changeset).segments
    end

    test "reports which segment of a thread is too long", %{user: user, account: account} do
      assert {:error, changeset} =
               Content.create_post(user, account, %{
                 segments: [%{"text" => "fine"}, %{"text" => String.duplicate("b", 300)}],
                 status: "draft"
               })

      assert "post 2 is over 280 characters" in errors_on(changeset).segments
    end

    test "drops trailing empty composer boxes", %{user: user, account: account} do
      {:ok, post} =
        Content.create_post(user, account, %{
          segments: [%{"text" => "real"}, %{"text" => "  "}, %{"text" => ""}],
          status: "draft"
        })

      assert length(post.segments) == 1
    end

    test "allows an empty draft but not an empty scheduled post", %{user: user, account: account} do
      assert {:ok, _} = Content.create_post(user, account, %{segments: [], status: "draft"})

      assert {:error, changeset} =
               Content.create_post(user, account, %{segments: [], status: "scheduled"})

      assert "must contain at least one post" in errors_on(changeset).segments
    end

    test "requires a time when scheduling", %{user: user, account: account} do
      assert {:error, changeset} =
               Content.create_post(user, account, %{
                 segments: [%{"text" => "hello"}],
                 status: "scheduled"
               })

      assert "is required to schedule a post" in errors_on(changeset).scheduled_at
    end
  end

  describe "next_open_slot_at/2" do
    test "returns nil when the account has no slots", %{user: user, account: account} do
      Enum.each(Content.list_slots(account), &Content.delete_slot(account, &1.id))

      assert Content.next_open_slot_at(account, user) == nil
    end

    test "returns a future time", %{user: user, account: account} do
      slot = Content.next_open_slot_at(account, user)

      assert %DateTime{} = slot
      assert DateTime.compare(slot, DateTime.utc_now()) == :gt
    end

    test "skips slots already taken", %{user: user, account: account} do
      first = Content.next_open_slot_at(account, user)

      {:ok, post} =
        Content.create_post(user, account, %{segments: [%{"text" => "one"}], status: "draft"})

      {:ok, _} = Content.schedule_post(post)

      second = Content.next_open_slot_at(account, user)

      assert DateTime.compare(second, first) == :gt
    end

    test "ignores disabled slots", %{user: user, account: account} do
      slots = Content.list_slots(account)
      Enum.each(slots, &Content.toggle_slot(account, &1.id))

      assert Content.next_open_slot_at(account, user) == nil
    end

    test "respects the user's time zone", %{user: user, account: account} do
      {:ok, user} = Accounts.update_user(user, %{timezone: "Asia/Kolkata"})

      slot = Content.next_open_slot_at(account, user)
      local = DateTime.shift_zone!(slot, "Asia/Kolkata", Tz.TimeZoneDatabase)

      # Default slots are all on the hour in local time.
      assert local.minute == 0
      assert local.hour in [9, 10, 11, 13]
    end
  end

  describe "scheduling" do
    test "schedule_post fills the next open slot", %{user: user, account: account} do
      {:ok, post} =
        Content.create_post(user, account, %{segments: [%{"text" => "hi"}], status: "draft"})

      assert {:ok, scheduled} = Content.schedule_post(post)
      assert scheduled.status == "scheduled"
      assert %DateTime{} = scheduled.scheduled_at
    end

    test "returns :no_slots when there is nowhere to put it", %{user: user, account: account} do
      Enum.each(Content.list_slots(account), &Content.delete_slot(account, &1.id))

      {:ok, post} =
        Content.create_post(user, account, %{segments: [%{"text" => "hi"}], status: "draft"})

      assert {:error, :no_slots} = Content.schedule_post(post)
    end

    test "claim_for_publishing succeeds once and then refuses", %{user: user, account: account} do
      {:ok, post} =
        Content.create_post(user, account, %{segments: [%{"text" => "hi"}], status: "draft"})

      {:ok, scheduled} = Content.schedule_post(post)

      assert {:ok, claimed} = Content.claim_for_publishing(scheduled.id)
      assert claimed.status == "publishing"

      # A second dispatcher tick must not publish the same post again.
      assert {:error, :already_claimed} = Content.claim_for_publishing(scheduled.id)
    end

    test "list_due_posts only returns posts whose time has passed", %{
      user: user,
      account: account
    } do
      {:ok, past} =
        Content.create_post(user, account, %{segments: [%{"text" => "past"}], status: "draft"})

      {:ok, _} =
        Content.schedule_post(past,
          at: DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
        )

      {:ok, future} =
        Content.create_post(user, account, %{segments: [%{"text" => "future"}], status: "draft"})

      {:ok, _} = Content.schedule_post(future)

      due_ids = Content.list_due_posts() |> Enum.map(& &1.id)

      assert past.id in due_ids
      refute future.id in due_ids
    end
  end

  describe "publishing outcomes" do
    setup %{user: user, account: account} do
      {:ok, post} =
        Content.create_post(user, account, %{segments: [%{"text" => "hi"}], status: "draft"})

      %{post: post}
    end

    test "mark_published records ids and a permalink", %{post: post} do
      assert {:ok, published} = Content.mark_published(post, ["12345"])

      assert published.status == "posted"
      assert published.x_post_ids == ["12345"]
      assert published.permalink == "https://x.com/i/status/12345"
      assert %DateTime{} = published.published_at
    end

    test "mark_failed stores the reason and bumps the attempt count", %{post: post} do
      assert {:ok, failed} = Content.mark_failed(post, "X returned 429")

      assert failed.status == "failed"
      assert failed.error == "X returned 429"
      assert failed.attempt_count == 1
    end

    test "retry_post only works on failures", %{post: post} do
      {:ok, failed} = Content.mark_failed(post, "boom")

      assert {:ok, retried} = Content.retry_post(failed)
      assert retried.status == "scheduled"
      assert retried.error == nil

      assert {:error, :not_failed} = Content.retry_post(retried)
    end
  end

  describe "shelf" do
    test "accepting a generation creates a draft and marks it used", %{
      user: user,
      account: account
    } do
      {:ok, generation} =
        Content.create_generation(%{
          user_id: user.id,
          x_account_id: account.id,
          segments: [%{"text" => "generated"}]
        })

      assert {:ok, post} = Content.accept_generation(user, generation)

      assert post.source == "generated"
      assert post.generation_id == generation.id
      assert Content.list_shelf(account) == []
    end

    test "shelf_deficit reports the shortfall per kind", %{user: user, account: account} do
      {:ok, _} =
        Content.create_generation(%{
          user_id: user.id,
          x_account_id: account.id,
          segments: [%{"text" => "one"}],
          kind: "for_you"
        })

      assert %{"for_you" => 2} = Content.shelf_deficit(account, %{"for_you" => 3})
    end
  end
end
