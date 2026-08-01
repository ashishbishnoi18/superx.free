defmodule SuperX.Content.Slot do
  @moduledoc """
  Projects a recurring local-time schedule into concrete queue openings.

  The recurrence is expanded in the user's timezone before it is converted
  to UTC. A 9am slot therefore stays at 9am when daylight-saving time moves
  the UTC offset, while a local time that does not exist during the spring
  transition is omitted rather than silently moved.

  Scheduled posts are fetched in one query and joined to their occurrences
  in memory. Posts such as immediate replies and retries that do not belong
  to the recurring grid remain available separately, so the richer view
  does not make exceptional work disappear.
  """

  import Ecto.Query

  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Content.{Post, ScheduleSlot}
  alias SuperX.Repo

  @default_weeks 4

  @type occurrence :: %{
          at: DateTime.t(),
          local_at: DateTime.t(),
          post: Post.t() | nil,
          schedule_slot: ScheduleSlot.t()
        }

  @doc """
  Returns the account's future slot occurrences over a bounded window.

  The window begins at `:now` and covers four weeks by default. `:now` is
  injectable so DST behaviour can be tested without changing the system
  clock.
  """
  @spec upcoming(XAccount.t(), User.t(), keyword()) :: [occurrence()]
  def upcoming(%XAccount{} = account, %User{} = user, opts \\ []) do
    account
    |> timeline(user, opts)
    |> Map.fetch!(:occurrences)
  end

  @doc """
  Returns both projected occurrences and scheduled posts outside the grid.

  The latter matters for immediate replies and retries: they publish through
  the same queue but were never assigned to a recurring opening.
  """
  @spec timeline(XAccount.t(), User.t(), keyword()) :: %{
          occurrences: [occurrence()],
          unslotted_posts: [Post.t()]
        }
  def timeline(%XAccount{} = account, %User{} = user, opts \\ []) do
    now = opts[:now] || DateTime.utc_now()
    weeks = opts[:weeks] || @default_weeks
    days = weeks * 7

    slots = enabled_slots(account)
    posts = scheduled_posts(account)

    with [_ | _] <- slots,
         {:ok, local_now} <- DateTime.shift_zone(now, user.timezone, Tz.TimeZoneDatabase) do
      posts_by_time = Map.new(posts, &{&1.scheduled_at, &1})
      slots_by_day = Enum.group_by(slots, & &1.day_of_week)
      today = DateTime.to_date(local_now)

      occurrences =
        0..(days - 1)
        |> Enum.flat_map(&occurrences_on(today, &1, slots_by_day, user.timezone, now))
        |> Enum.sort_by(& &1.at, DateTime)
        |> Enum.map(&Map.put(&1, :post, posts_by_time[&1.at]))

      matched_post_ids =
        occurrences
        |> Enum.flat_map(fn
          %{post: %Post{id: id}} -> [id]
          _occurrence -> []
        end)
        |> MapSet.new()

      %{
        occurrences: occurrences,
        unslotted_posts: Enum.reject(posts, &MapSet.member?(matched_post_ids, &1.id))
      }
    else
      _ -> %{occurrences: [], unslotted_posts: posts}
    end
  end

  defp enabled_slots(account) do
    ScheduleSlot
    |> where(x_account_id: ^account.id, enabled: true)
    |> order_by([slot], asc: slot.day_of_week, asc: slot.time)
    |> Repo.all()
  end

  defp scheduled_posts(account) do
    Post
    |> where([post], post.x_account_id == ^account.id and post.status == "scheduled")
    |> order_by([post], asc: post.scheduled_at)
    |> Repo.all()
  end

  defp occurrences_on(today, offset, slots_by_day, timezone, now) do
    date = Date.add(today, offset)
    day_of_week = Date.day_of_week(date, :sunday) - 1

    slots_by_day
    |> Map.get(day_of_week, [])
    |> Enum.flat_map(&occurrence(&1, date, timezone, now))
  end

  defp occurrence(schedule_slot, date, timezone, now) do
    case DateTime.new(date, schedule_slot.time, timezone, Tz.TimeZoneDatabase) do
      {:ok, local_at} ->
        at = local_at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

        if DateTime.compare(at, now) == :gt do
          [%{at: at, local_at: local_at, post: nil, schedule_slot: schedule_slot}]
        else
          []
        end

      _ ->
        []
    end
  end
end
