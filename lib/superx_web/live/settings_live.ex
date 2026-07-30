defmodule SuperXWeb.SettingsLive do
  @moduledoc """
  Posting schedule, time zone, and the shelf mix.
  """

  use SuperXWeb, :live_view

  alias SuperX.{Accounts, Content}
  alias SuperX.Content.ScheduleSlot

  @common_timezones [
    "Etc/UTC",
    "America/Los_Angeles",
    "America/New_York",
    "Europe/London",
    "Europe/Berlin",
    "Asia/Dubai",
    "Asia/Kolkata",
    "Asia/Singapore",
    "Asia/Tokyo",
    "Australia/Sydney"
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Settings")
     |> assign(:timezones, timezones(socket.assigns.current_user.timezone))
     |> assign(:new_day, "1")
     |> assign(:new_time, "09:00")
     |> load()}
  end

  defp timezones(current) do
    Enum.uniq([current | @common_timezones])
  end

  defp load(socket) do
    assign(socket, :slots, Content.list_slots(socket.assigns.current_x_account))
  end

  @impl true
  def handle_event("add_slot", %{"day_of_week" => day, "time" => time}, socket) do
    with {:ok, parsed} <- Time.from_iso8601(time <> ":00"),
         {:ok, _slot} <-
           Content.create_slot(socket.assigns.current_x_account, %{
             day_of_week: String.to_integer(day),
             time: parsed
           }) do
      {:noreply, socket |> put_flash(:info, "Slot added.") |> load()}
    else
      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "There's already a slot at that time.")}

      _ ->
        {:noreply, put_flash(socket, :error, "That time didn't look right.")}
    end
  end

  def handle_event("toggle_slot", %{"id" => id}, socket) do
    Content.toggle_slot(socket.assigns.current_x_account, id)
    {:noreply, load(socket)}
  end

  def handle_event("delete_slot", %{"id" => id}, socket) do
    Content.delete_slot(socket.assigns.current_x_account, id)
    {:noreply, socket |> put_flash(:info, "Slot removed.") |> load()}
  end

  def handle_event("set_timezone", %{"timezone" => timezone}, socket) do
    case Accounts.update_user(socket.assigns.current_user, %{timezone: timezone}) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> put_flash(:info, "Time zone updated. Your slots now follow #{timezone}.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "That time zone isn't recognised.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header
      title="Schedule"
      description="When you post, and in which time zone. Slots are stored as local times, so a 9am slot stays 9am through daylight saving."
    />

    <div class="grid grid-cols-1 gap-7 border-t border-border py-6 sm:grid-cols-[14rem_minmax(0,1fr)]">
      <div>
        <label class="label" for="timezone">Time zone</label>
        <p class="text-[12px] leading-[1.6] text-faint">Everything below is written in this zone.</p>
      </div>
      <form phx-change="set_timezone">
        <select id="timezone" name="timezone" class="select">
          <option :for={tz <- @timezones} value={tz} selected={@current_user.timezone == tz}>
            {tz}
          </option>
        </select>
      </form>
    </div>

    <div class="grid grid-cols-1 gap-7 border-t border-border py-6 sm:grid-cols-[14rem_minmax(0,1fr)]">
      <div>
        <span class="label">Posting times</span>
        <p class="text-[12px] leading-[1.6] text-faint">
          Approved drafts fill the next opening. Pause one to skip it without losing it.
        </p>
      </div>

      <div>
        <p :if={@slots == []} class="text-muted-foreground">
          No times yet. Add the first one below.
        </p>

        <ul class="flex flex-col">
          <li
            :for={slot <- @slots}
            class="flex items-baseline gap-4 border-b border-border py-2.5 first:border-t"
          >
            <span class={[
              "nb-mono w-24 text-[11px]",
              if(slot.enabled, do: "text-muted-foreground", else: "text-faint line-through")
            ]}>
              {ScheduleSlot.day_name(slot)}
            </span>
            <span class={[
              "nb-mono flex-1 text-[13px]",
              !slot.enabled && "text-faint line-through"
            ]}>
              {format_time(slot.time)}
            </span>

            <button phx-click="toggle_slot" phx-value-id={slot.id} class="act text-xs">
              {if slot.enabled, do: "Pause", else: "Resume"}
            </button>
            <button phx-click="delete_slot" phx-value-id={slot.id} class="act-danger text-xs">
              Remove
            </button>
          </li>
        </ul>

        <form phx-submit="add_slot" class="mt-5 flex flex-wrap items-end gap-5">
          <div>
            <label class="label" for="day_of_week">Day</label>
            <select id="day_of_week" name="day_of_week" class="select w-auto pr-6">
              <option :for={dow <- 0..6} value={dow} selected={dow == 1}>
                {ScheduleSlot.day_name(dow)}
              </option>
            </select>
          </div>

          <div>
            <label class="label" for="time">Time</label>
            <input type="time" id="time" name="time" value="09:00" class="input w-auto" required />
          </div>

          <button type="submit" class="act-key pb-2 text-xs">Add time</button>
        </form>
      </div>
    </div>
    """
  end

  defp format_time(%Time{} = time), do: Calendar.strftime(time, "%-I:%M %p")
end
