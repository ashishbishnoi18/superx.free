defmodule SuperX.Content.SlotTest do
  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.{Accounts, Content}
  alias SuperX.Content.Slot

  test "keeps a local slot fixed when daylight-saving time changes" do
    %{user: user, account: account} = user_fixture()
    {:ok, user} = Accounts.update_user(user, %{timezone: "America/New_York"})

    Enum.each(Content.list_slots(account), &Content.delete_slot(account, &1.id))
    {:ok, _slot} = Content.create_slot(account, %{day_of_week: 0, time: ~T[09:00:00]})

    timeline =
      Slot.timeline(account, user,
        weeks: 2,
        now: ~U[2026-03-01 13:30:00Z]
      )

    [before_dst, after_dst] = timeline.occurrences

    assert {before_dst.local_at.hour, before_dst.at.hour} == {9, 14}
    assert {after_dst.local_at.hour, after_dst.at.hour} == {9, 13}
  end

  test "joins scheduled posts to occurrences without hiding posts outside the grid" do
    %{user: user, account: account} = user_fixture()
    [opening | _] = Slot.upcoming(account, user)

    {:ok, slotted} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "In the recurring grid"}],
        status: "draft"
      })

    {:ok, slotted} = Content.schedule_post(slotted, at: opening.at)
    {:ok, _publishing} = Content.claim_for_publishing(slotted.id)

    {:ok, immediate} =
      Content.create_post(user, account, %{
        segments: [%{"text" => "Publishing outside the grid"}],
        status: "draft"
      })

    at = DateTime.utc_now() |> DateTime.add(120) |> DateTime.truncate(:second)
    {:ok, immediate} = Content.schedule_post(immediate, at: at)

    timeline = Slot.timeline(account, user)

    assert Enum.any?(
             timeline.occurrences,
             &(&1.post && &1.post.id == slotted.id && &1.post.status == "publishing")
           )

    assert Enum.map(timeline.unslotted_posts, & &1.id) == [immediate.id]
  end
end
