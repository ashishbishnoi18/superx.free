defmodule SuperX.Content.Week do
  @moduledoc """
  Builds the week grid behind the queue's calendar view.

  The grid is driven by the account's slots, not by the clock: rows are
  the distinct times the user actually posts at, so an account that posts
  twice a week gets two rows rather than twenty-four. An empty cell means
  a real opening, which is the thing the screen exists to show.
  """

  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Content
  alias SuperX.Content.{Post, ScheduleSlot}

  @doc """
  Returns `%{days: [...], rows: [...], start: Date.t()}` for the week
  containing `anchor`, in the user's local time.

  Each row is `%{time: Time.t(), cells: [cell]}` where a cell is
  `%{date:, slot:, post:, past?:}`.
  """
  def build(%XAccount{} = account, %User{} = user, anchor \\ nil) do
    tz = user.timezone
    anchor = anchor || today_in(tz)
    start = week_start(anchor)
    days = Enum.map(0..6, &Date.add(start, &1))

    slots = account |> Content.list_slots() |> Enum.filter(& &1.enabled)
    times = slots |> Enum.map(& &1.time) |> Enum.uniq() |> Enum.sort(Time)

    scheduled = scheduled_by_local_time(account, start, tz)
    now = DateTime.utc_now()

    rows =
      Enum.map(times, fn time ->
        cells =
          Enum.map(days, fn date ->
            dow = Date.day_of_week(date, :sunday) - 1
            slot = Enum.find(slots, &(&1.day_of_week == dow and &1.time == time))

            %{
              date: date,
              slot: slot,
              post: scheduled[{date, time}],
              past?: past?(date, time, tz, now)
            }
          end)

        %{time: time, cells: cells}
      end)

    %{start: start, days: days, rows: rows, today: today_in(tz)}
  end

  @doc "The week containing a date, starting Sunday to match the slot grid."
  def week_start(%Date{} = date), do: Date.add(date, -(Date.day_of_week(date, :sunday) - 1))

  @doc "Today, in the user's zone rather than the server's."
  def today_in(tz) do
    case DateTime.now(tz, Tz.TimeZoneDatabase) do
      {:ok, dt} -> DateTime.to_date(dt)
      _ -> Date.utc_today()
    end
  end

  # Scheduled posts keyed by the local date and time they land on, so a
  # cell lookup is a map read rather than a scan per cell.
  defp scheduled_by_local_time(account, start, tz) do
    from = to_utc(start, ~T[00:00:00], tz)
    to = to_utc(Date.add(start, 7), ~T[00:00:00], tz)

    import Ecto.Query

    Post
    |> where([p], p.x_account_id == ^account.id and p.status == "scheduled")
    |> where([p], p.scheduled_at >= ^from and p.scheduled_at < ^to)
    |> SuperX.Repo.all()
    |> Map.new(fn post ->
      local = DateTime.shift_zone!(post.scheduled_at, tz, Tz.TimeZoneDatabase)
      {{DateTime.to_date(local), truncate_to_minute(DateTime.to_time(local))}, post}
    end)
  end

  defp truncate_to_minute(%Time{} = time), do: %{time | second: 0, microsecond: {0, 0}}

  defp to_utc(date, time, tz) do
    case DateTime.new(date, time, tz, Tz.TimeZoneDatabase) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      # A DST spring-forward can erase a local midnight; the surrounding
      # hour is close enough for a week boundary.
      _ -> DateTime.new!(date, time, "Etc/UTC")
    end
  end

  defp past?(date, time, tz, now) do
    case DateTime.new(date, time, tz, Tz.TimeZoneDatabase) do
      {:ok, dt} -> DateTime.compare(DateTime.shift_zone!(dt, "Etc/UTC"), now) == :lt
      _ -> false
    end
  end

  @doc "Short day label for a column header."
  def day_label(%Date{} = date), do: Calendar.strftime(date, "%a")

  @doc "Human label for the week being shown."
  def range_label(%Date{} = start) do
    finish = Date.add(start, 6)

    if start.month == finish.month do
      "#{Calendar.strftime(start, "%-d")}–#{Calendar.strftime(finish, "%-d %b")}"
    else
      "#{Calendar.strftime(start, "%-d %b")} – #{Calendar.strftime(finish, "%-d %b")}"
    end
  end

  @doc "Day-of-week name, matching the slot editor."
  def day_name(dow), do: ScheduleSlot.day_name(dow)
end
