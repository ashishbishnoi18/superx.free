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
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold tracking-tight">Settings</h1>
        <p class="mt-1 text-sm" style="color: var(--text-secondary)">
          When you post, and in which time zone.
        </p>
      </div>

      <section class="card p-5">
        <h2 class="font-semibold">Time zone</h2>
        <p class="mt-1 text-xs" style="color: var(--text-secondary)">
          Slots are stored as local times, so they hold through daylight saving.
        </p>

        <form phx-change="set_timezone" class="mt-3">
          <select name="timezone" class="select">
            <option :for={tz <- @timezones} value={tz} selected={@current_user.timezone == tz}>
              {tz}
            </option>
          </select>
        </form>
      </section>

      <section class="card p-5">
        <h2 class="font-semibold">Posting times</h2>
        <p class="mt-1 text-xs" style="color: var(--text-secondary)">
          Approved posts fill the next open slot automatically.
        </p>

        <div :if={@slots == []} class="mt-4 rounded-xl p-4 text-center text-sm"
             style="background-color: var(--surface-sunken); color: var(--text-secondary)">
          No slots yet. Add a few below.
        </div>

        <ul class="mt-4 space-y-2">
          <li
            :for={slot <- @slots}
            class="flex items-center gap-3 rounded-xl px-3 py-2"
            style="background-color: var(--surface-sunken)"
          >
            <button
              phx-click="toggle_slot"
              phx-value-id={slot.id}
              class="shrink-0"
              title={if slot.enabled, do: "Disable", else: "Enable"}
            >
              <.icon
                name={if slot.enabled, do: "hero-check-circle-solid", else: "hero-pause-circle"}
                class={["size-5", slot.enabled && "text-ember-600"]}
              />
            </button>

            <span class={["flex-1 text-sm", !slot.enabled && "line-through opacity-50"]}>
              <span class="font-medium">{ScheduleSlot.day_name(slot)}</span>
              at {format_time(slot.time)}
            </span>

            <button
              phx-click="delete_slot"
              phx-value-id={slot.id}
              class="btn btn-ghost btn-sm"
              title="Remove"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </li>
        </ul>

        <form phx-submit="add_slot" class="mt-4 flex flex-wrap items-end gap-3">
          <div>
            <label class="label" for="day_of_week">Day</label>
            <select id="day_of_week" name="day_of_week" class="select w-auto">
              <option :for={dow <- 0..6} value={dow} selected={dow == 1}>
                {ScheduleSlot.day_name(dow)}
              </option>
            </select>
          </div>

          <div>
            <label class="label" for="time">Time</label>
            <input type="time" id="time" name="time" value="09:00" class="input w-auto" required />
          </div>

          <button type="submit" class="btn btn-secondary">
            <.icon name="hero-plus" class="size-4" /> Add slot
          </button>
        </form>
      </section>
    </div>
    """
  end

  defp format_time(%Time{} = time), do: Calendar.strftime(time, "%-I:%M %p")
end
