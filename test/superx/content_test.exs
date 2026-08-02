defmodule SuperX.ContentTest do
  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.{Accounts, Content}

  setup do
    user_fixture()
  end

  describe "post validation" do
    test "scopes posts and generations to the selected account", %{user: user, account: account} do
      {:ok, _subscription} =
        SuperX.Billing.upsert_subscription(user, %{tier: "pro", status: "active"})

      {:ok, second_account} =
        SuperX.Accounts.Connect.attach(
          user,
          %{
            x_user_id: "content-second-#{System.unique_integer([:positive])}",
            handle: "content_second"
          },
          %{access_token: "second-token"}
        )

      {:ok, post} =
        Content.create_post(user, account, %{
          segments: [%{"text" => "first account"}],
          status: "draft"
        })

      {:ok, generation} =
        Content.create_generation(%{
          user_id: user.id,
          x_account_id: account.id,
          segments: [%{"text" => "first account draft"}]
        })

      assert Content.get_post(user, second_account, post.id) == nil
      assert Content.get_generation(user, second_account, generation.id) == nil
    end

    test "rejects attachment keys without matching ownership", %{user: user, account: account} do
      unavailable = "00000000-0000-0000-0000-000000000001.jpg"

      assert {:error, changeset} =
               Content.create_post(user, account, %{
                 segments: [%{"text" => "not mine", "media_ids" => [unavailable]}],
                 status: "draft"
               })

      assert "contains an unavailable attachment" in errors_on(changeset).segments
    end

    test "rejects malformed attachment identifiers without raising", %{
      user: user,
      account: account
    } do
      assert {:error, changeset} =
               Content.create_post(user, account, %{
                 segments: [%{"text" => "malformed", "media_ids" => [%{"bad" => "shape"}]}],
                 status: "draft"
               })

      assert "contains an unavailable attachment" in errors_on(changeset).segments
    end

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

    test "rejects more media than X accepts on one segment", %{user: user, account: account} do
      media_ids = Enum.map(1..5, &"00000000-0000-0000-0000-00000000000#{&1}.jpg")

      assert {:error, changeset} =
               Content.create_post(user, account, %{
                 segments: [%{"text" => "too many", "media_ids" => media_ids}],
                 status: "draft"
               })

      assert "post 1 has more than 4 attachments" in errors_on(changeset).segments
    end

    test "rejects a GIF mixed with other media", %{user: user, account: account} do
      assert {:error, changeset} =
               Content.create_post(user, account, %{
                 segments: [
                   %{
                     "text" => "mixed",
                     "media_ids" => [
                       "00000000-0000-0000-0000-000000000001.gif",
                       "00000000-0000-0000-0000-000000000002.jpg"
                     ]
                   }
                 ],
                 status: "draft"
               })

      assert "post 1 must attach a GIF on its own" in errors_on(changeset).segments
    end

    test "rejects automation thresholds that are not positive", %{user: user, account: account} do
      assert {:error, changeset} =
               Content.create_post(user, account, %{
                 segments: [%{"text" => "hi"}],
                 status: "draft",
                 auto_retweet_hours: -2
               })

      assert "must be greater than 0" in errors_on(changeset).auto_retweet_hours

      assert {:error, changeset} =
               Content.create_post(user, account, %{
                 segments: [%{"text" => "hi"}],
                 status: "draft",
                 auto_delete_min_views: 0
               })

      assert "must be greater than 0" in errors_on(changeset).auto_delete_min_views
    end

    test "requires plug text when plug likes is set", %{user: user, account: account} do
      assert {:error, changeset} =
               Content.create_post(user, account, %{
                 segments: [%{"text" => "hi"}],
                 status: "draft",
                 auto_plug_likes: 50
               })

      assert "is required when auto plug likes is set" in errors_on(changeset).auto_plug_text
    end

    test "accepts a valid automation setup", %{user: user, account: account} do
      assert {:ok, post} =
               Content.create_post(user, account, %{
                 segments: [%{"text" => "hi"}],
                 status: "draft",
                 auto_retweet_hours: 12,
                 auto_plug_likes: 50,
                 auto_plug_text: "follow for more"
               })

      assert post.auto_retweet_hours == 12
      assert post.auto_plug_text == "follow for more"
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
      assert Content.post_counts(account)["scheduled"] == 1

      # A second dispatcher tick must not publish the same post again.
      assert {:error, :already_claimed} = Content.claim_for_publishing(scheduled.id)

      # Nor may a stale queue page move a post back to drafts after the
      # publisher has claimed it.
      assert {:error, :not_scheduled} = Content.unschedule_post(claimed)
      assert Content.get_post(user, account, claimed.id).status == "publishing"
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
      assert retried.segments == post.segments

      assert {:error, :not_failed} = Content.retry_post(retried)
    end

    test "does not retry a thread after some segments already published", %{
      user: user,
      account: account,
      post: post
    } do
      partial =
        post
        |> Ecto.Changeset.change(status: "failed", x_post_ids: ["already-live"])
        |> SuperX.Repo.update!()

      assert {:error, :partial_publish} = Content.retry_post(partial)
      assert Content.get_post(user, account, partial.id).status == "failed"
    end
  end

  describe "automation bookkeeping" do
    setup %{user: user, account: account} do
      {:ok, post} =
        Content.create_post(user, account, %{segments: [%{"text" => "hi"}], status: "draft"})

      %{post: post}
    end

    test "update_automation_state merges markers instead of replacing them", %{post: post} do
      assert {:ok, post} = Content.update_automation_state(post, %{"auto_retweeted_at" => "t1"})
      assert {:ok, post} = Content.update_automation_state(post, %{"auto_plugged_at" => "t2"})

      assert post.automation_state == %{"auto_retweeted_at" => "t1", "auto_plugged_at" => "t2"}
    end

    test "update_metrics stamps when the metrics were fetched", %{post: post} do
      assert {:ok, post} = Content.update_metrics(post, %{"views" => 42})

      assert post.metrics == %{"views" => 42}
      assert %DateTime{} = post.metrics_updated_at
    end

    test "only one stale worker can claim an external action", %{post: post} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, claimed} = Content.claim_automation_action(post, "retweet", now)
      assert {:error, :already_claimed} = Content.claim_automation_action(post, "retweet", now)
      assert claimed.automation_state["claimed_retweet_at"]

      assert {:ok, completed} =
               Content.complete_automation_action(claimed, "retweet", now)

      assert completed.automation_state["retweeted_at"]
      refute completed.automation_state["claimed_retweet_at"]
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

    test "a filled opening does not consume another shelf draft", %{
      user: user,
      account: account
    } do
      at = Content.next_open_slot_at(account, user)

      {:ok, first} =
        Content.create_generation(%{
          user_id: user.id,
          x_account_id: account.id,
          segments: [%{"text" => "first"}]
        })

      {:ok, second} =
        Content.create_generation(%{
          user_id: user.id,
          x_account_id: account.id,
          segments: [%{"text" => "second"}]
        })

      assert {:ok, scheduled} = Content.accept_generation_into_slot(user, first, at)
      assert scheduled.scheduled_at == at
      assert {:error, :slot_taken} = Content.accept_generation_into_slot(user, second, at)
      assert Content.get_generation(user, account, second.id).status == "shelf"

      next_at = Content.next_open_slot_at(account, user)
      assert {:error, :not_on_shelf} = Content.accept_generation_into_slot(user, first, next_at)
    end
  end

  describe "tags" do
    test "list_posts filters to posts carrying the tag", %{user: user, account: account} do
      {:ok, tagged} =
        Content.create_post(user, account, %{
          segments: [%{"text" => "tagged"}],
          status: "draft",
          tags: ["ai", "devlog"]
        })

      {:ok, _other} =
        Content.create_post(user, account, %{
          segments: [%{"text" => "other"}],
          status: "draft",
          tags: ["random"]
        })

      {:ok, _untagged} =
        Content.create_post(user, account, %{segments: [%{"text" => "untagged"}], status: "draft"})

      assert [found] = Content.list_posts(account, "draft", tag: "ai")
      assert found.id == tagged.id
      assert length(Content.list_posts(account, "draft")) == 3
      assert Content.list_posts(account, "draft", tag: "nobody-uses-this") == []
    end

    test "list_tags returns the account's distinct tags, sorted", %{user: user, account: account} do
      for {text, tags} <- [{"one", ["devlog", "ai"]}, {"two", ["ai", "launch"]}, {"three", []}] do
        {:ok, _} =
          Content.create_post(user, account, %{
            segments: [%{"text" => text}],
            status: "draft",
            tags: tags
          })
      end

      # Another account's tags must not leak into the menu.
      %{user: other_user, account: other_account} = user_fixture()

      {:ok, _} =
        Content.create_post(other_user, other_account, %{
          segments: [%{"text" => "elsewhere"}],
          status: "draft",
          tags: ["zzz-other"]
        })

      assert Content.list_tags(account) == ["ai", "devlog", "launch"]
    end
  end
end
