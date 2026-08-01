defmodule SuperX.AnalyticsTest do
  @moduledoc """
  Imported history and follower attribution can silently rewrite the numbers
  people make decisions from. These tests pin the provenance boundary, the
  anchored reconstruction, and the intentionally coarse attribution rule.
  """

  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.Analytics
  alias SuperX.Analytics.Snapshot
  alias SuperX.Content
  alias SuperX.Repo

  setup do
    user_fixture(followers_count: 110)
  end

  describe "import_history/2" do
    test "backfills missing dates but never replaces a collected snapshot", %{account: account} do
      today = Date.utc_today()

      {:ok, _snapshot} =
        Analytics.record_snapshot(account, today, %{
          followers: 110,
          following: 50,
          posts: 10,
          impressions: 77
        })

      csv =
        <<0xEF, 0xBB, 0xBF>> <>
          "Day,Followers Count,Posts Count,Post Impressions,Engagements\r\n" <>
          "#{Date.add(today, -1)},105,9,\"1,200\",40\r\n" <>
          "#{today},999,999,9999,999\r\n"

      assert {:ok, report} = Analytics.import_history(account, csv)
      assert report.imported == 1
      assert report.skipped_existing == 1
      assert report.skipped_invalid == 0
      assert report.recognised == [:followers, :posts, :impressions, :engagements]

      imported = Repo.get_by!(Snapshot, x_account_id: account.id, date: Date.add(today, -1))
      collected = Repo.get_by!(Snapshot, x_account_id: account.id, date: today)

      assert imported.source == "imported"
      assert imported.followers == 105
      assert imported.posts == 9
      assert imported.impressions == 1_200

      assert collected.source == "collected"
      assert collected.followers == 110
      assert collected.posts == 10
      assert collected.impressions == 77
    end

    test "rebuilds lifetime totals from daily changes and a collected anchor", %{account: account} do
      today = Date.utc_today()

      {:ok, _snapshot} =
        Analytics.record_snapshot(account, today, %{
          followers: 110,
          following: 50,
          posts: 10
        })

      csv =
        "Date,New Followers,Unfollows,Posts,Impressions,Likes,Replies,Retweets,Profile Visits\n" <>
          "#{Date.add(today, -2)},3,1,2,400,10,2,3,7\n" <>
          "#{Date.add(today, -1)},4,1,1,500,12,3,4,8\n" <>
          "#{today},2,0,1,600,14,4,5,9\n"

      assert {:ok, report} = Analytics.import_history(account, csv)
      assert report.imported == 2
      assert report.skipped_existing == 1

      [older, newer, collected] =
        Analytics.list_snapshots(account, Date.add(today, -2), today)

      assert {older.followers, newer.followers, collected.followers} == {105, 107, 110}
      assert {older.posts, newer.posts, collected.posts} == {7, 9, 10}
      assert newer.reposts == 4
      assert newer.profile_clicks == 8
    end

    test "lets a later collector replace an imported date", %{account: account} do
      date = Date.add(Date.utc_today(), -1)

      assert {:ok, %{imported: 1}} =
               Analytics.import_history(account, "Date,Followers\n#{date},105\n")

      assert Repo.get_by!(Snapshot, x_account_id: account.id, date: date).source == "imported"

      assert {:ok, _snapshot} =
               Analytics.record_snapshot(account, date, %{
                 followers: 107,
                 following: 50,
                 posts: 10
               })

      snapshot = Repo.get_by!(Snapshot, x_account_id: account.id, date: date)
      assert snapshot.source == "collected"
      assert snapshot.followers == 107
    end

    test "reports duplicate, malformed and unanchored rows separately", %{account: account} do
      csv =
        "Time,New followers,Unfollows\n" <>
          "2020-01-01,3,1\n" <>
          "2020-01-01,4,0\n" <>
          "not-a-date,2,0\n"

      assert {:ok, report} = Analytics.import_history(account, csv)
      assert report.imported == 0
      assert report.skipped_duplicate == 1
      assert report.skipped_invalid == 2
      assert report.skipped_existing == 0
    end

    test "rejects exports without the columns needed to anchor follower history", %{
      account: account
    } do
      assert {:error, :missing_date} =
               Analytics.import_history(account, "Impressions,Engagements\n12,3\n")

      assert {:error, :missing_followers} =
               Analytics.import_history(account, "Date,Impressions\n2026-01-01,12\n")
    end
  end

  describe "follower_gain_posts/4" do
    test "shares one day's gain across its posts and ignores snapshot gaps", %{
      user: user,
      account: account
    } do
      today = Date.utc_today()
      from = Date.add(today, -4)

      record(account, Date.add(today, -4), 100)
      record(account, Date.add(today, -3), 106)
      record(account, Date.add(today, -2), 110)
      record(account, today, 130)

      first = published_post(user, account, Date.add(today, -4), "first structure")
      second = published_post(user, account, Date.add(today, -4), "second structure")
      winner = published_post(user, account, Date.add(today, -3), "winning structure")
      gap = published_post(user, account, Date.add(today, -2), "gap structure")

      ranked = Analytics.follower_gain_posts(account, from, today, 5)

      assert [%{post: ^winner, estimated_followers: 4.0} | tied] = ranked
      assert MapSet.new(Enum.map(tied, & &1.post.id)) == MapSet.new([first.id, second.id])
      assert Enum.all?(tied, &(&1.estimated_followers == 3.0))
      refute Enum.any?(ranked, &(&1.post.id == gap.id))
    end
  end

  describe "public shares" do
    test "fixes the window, rotates the token and revokes the old capability", %{account: account} do
      today = Date.utc_today()
      from = Date.add(today, -7)
      record(account, from, 100)
      record(account, today, 110)

      assert {:ok, first} = Analytics.create_share(account, from, today)
      assert String.length(first.token) == 43

      assert public = Analytics.public_share(first.token)
      assert Map.keys(public) |> Enum.sort() == [:account, :from_date, :summary, :to_date]

      assert Map.keys(public.summary) |> Enum.sort() ==
               [:engagements, :followers, :followers_change, :impressions, :posts, :series]

      assert Enum.all?(public.summary.series, fn point ->
               Map.keys(point) |> Enum.sort() == [:date, :followers]
             end)

      assert public.summary.followers_change == 10

      assert {:ok, second} = Analytics.create_share(account, from, Date.add(today, -1))
      refute second.token == first.token
      assert Analytics.public_share(first.token) == nil

      assert :ok = Analytics.revoke_share(account)
      assert Analytics.public_share(second.token) == nil
    end
  end

  defp record(account, date, followers) do
    {:ok, snapshot} =
      Analytics.record_snapshot(account, date, %{
        followers: followers,
        following: 50,
        posts: 10
      })

    snapshot
  end

  defp published_post(user, account, date, text) do
    {:ok, post} =
      Content.create_post(user, account, %{
        status: "draft",
        segments: [%{"text" => text}]
      })

    post
    |> Ecto.Changeset.change(%{
      status: "posted",
      published_at: DateTime.new!(date, ~T[12:00:00], "Etc/UTC")
    })
    |> Repo.update!()
  end
end
