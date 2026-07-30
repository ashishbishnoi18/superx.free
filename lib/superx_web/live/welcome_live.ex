defmodule SuperXWeb.WelcomeLive do
  @moduledoc """
  Guided setup after connecting an account.

  Two things decide whether the product works for someone: whether it
  knows how they write, and whether it knows when they want to post.
  Leaving both to be discovered under Settings meant a new user's first
  drafts were generic and never went anywhere.

  Both steps are skippable. Someone who wants to write their own posts on
  their own schedule shouldn't be held at a wizard.
  """

  use SuperXWeb, :live_view

  alias SuperX.{Accounts, Content}
  alias SuperX.Content.Voice

  @presets [
    {"weekday_mornings", "Weekday mornings",
     [{1, ~T[09:00:00]}, {2, ~T[09:00:00]}, {3, ~T[09:00:00]}, {4, ~T[09:00:00]},
      {5, ~T[09:00:00]}]},
    {"three_a_week", "Three times a week",
     [{1, ~T[10:00:00]}, {3, ~T[10:00:00]}, {5, ~T[10:00:00]}]},
    {"twice_daily", "Twice a day, weekdays",
     [{1, ~T[09:00:00]}, {1, ~T[16:00:00]}, {2, ~T[09:00:00]}, {2, ~T[16:00:00]},
      {3, ~T[09:00:00]}, {3, ~T[16:00:00]}, {4, ~T[09:00:00]}, {4, ~T[16:00:00]},
      {5, ~T[09:00:00]}, {5, ~T[16:00:00]}]}
  ]

  @impl true
  def mount(_params, _session, socket) do
    account = socket.assigns.current_x_account

    {:ok,
     socket
     |> assign(page_title: "Welcome")
     |> assign(:step, :voice)
     |> assign(:deriving, false)
     |> assign(:presets, @presets)
     |> assign(:timezones, timezones(socket.assigns.current_user.timezone))
     |> assign(:ai_configured, SuperX.AI.configured?())
     |> assign(:voice, Content.get_voice_profile(account))}
  end

  defp timezones(current) do
    Enum.uniq([
      current,
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
    ])
  end

  @impl true
  def handle_event("derive", _params, socket) do
    account = socket.assigns.current_x_account
    parent = self()

    Task.Supervisor.start_child(SuperX.TaskSupervisor, fn ->
      send(parent, {:derived, Voice.derive(account)})
    end)

    {:noreply, assign(socket, :deriving, true)}
  end

  def handle_event("save_voice", %{"about" => about, "topics" => topics}, socket) do
    {:ok, profile} = Content.get_or_create_voice_profile(socket.assigns.current_x_account)

    {:ok, voice} =
      Content.update_voice_profile(profile, %{about: about, topics: topics})

    {:noreply, socket |> assign(:voice, voice) |> assign(:step, :schedule)}
  end

  def handle_event("skip_voice", _params, socket), do: {:noreply, assign(socket, :step, :schedule)}

  def handle_event("back", _params, socket), do: {:noreply, assign(socket, :step, :voice)}

  def handle_event("set_timezone", %{"timezone" => timezone}, socket) do
    case Accounts.update_user(socket.assigns.current_user, %{timezone: timezone}) do
      {:ok, user} -> {:noreply, assign(socket, :current_user, user)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "That time zone isn't recognised.")}
    end
  end

  def handle_event("choose_preset", %{"preset" => key}, socket) do
    account = socket.assigns.current_x_account

    # Replace rather than add: the account was seeded with defaults at
    # connect time, and layering a preset on top would silently double
    # someone's posting rate.
    Enum.each(Content.list_slots(account), &Content.delete_slot(account, &1.id))

    case Enum.find(@presets, fn {k, _, _} -> k == key end) do
      nil ->
        {:noreply, socket}

      {_key, _label, slots} ->
        Enum.each(slots, fn {day, time} ->
          Content.create_slot(account, %{day_of_week: day, time: time})
        end)

        {:noreply, finish(socket)}
    end
  end

  def handle_event("skip_schedule", _params, socket), do: {:noreply, finish(socket)}

  @impl true
  def handle_info({:derived, {:ok, voice}}, socket) do
    {:noreply,
     socket
     |> assign(:deriving, false)
     |> assign(:voice, voice)
     |> put_flash(:info, "Read your recent posts.")}
  end

  def handle_info({:derived, {:error, reason}}, socket) do
    require Logger
    Logger.warning("Onboarding voice derivation failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:deriving, false)
     |> put_flash(:error, "Couldn't read your posts. You can fill this in yourself.")}
  end

  defp finish(socket) do
    {:ok, _user} =
      Accounts.update_user(socket.assigns.current_user, %{
        onboarding_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    push_navigate(socket, to: ~p"/home")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-[58ch] py-10">
      <p class="nb-eyebrow mb-6">
        Step {if @step == :voice, do: "1", else: "2"} of 2
      </p>

      <.voice_step
        :if={@step == :voice}
        voice={@voice}
        deriving={@deriving}
        ai_configured={@ai_configured}
        account={@current_x_account}
      />

      <.schedule_step
        :if={@step == :schedule}
        presets={@presets}
        timezones={@timezones}
        current_user={@current_user}
      />
    </div>
    """
  end

  attr :voice, :any, required: true
  attr :deriving, :boolean, required: true
  attr :ai_configured, :boolean, required: true
  attr :account, :map, required: true

  defp voice_step(assigns) do
    ~H"""
    <h1 class="text-[1.75rem] font-semibold leading-[1.15] tracking-[-0.03em]">
      How do you write?
    </h1>
    <p class="mt-3 leading-[1.6] text-muted-foreground">
      This is what keeps drafts sounding like you instead of like an assistant.
      SuperX can read your recent posts and work it out, or you can just tell it.
    </p>

    <button
      :if={@ai_configured}
      phx-click="derive"
      disabled={@deriving}
      class="act-key mt-6 inline-block"
    >
      {if @deriving, do: "Reading @#{@account.handle}…", else: "Read my recent posts →"}
    </button>

    <form phx-submit="save_voice" class="mt-8 flex flex-col gap-6">
      <div>
        <label class="label" for="about">What you write about</label>
        <textarea
          id="about"
          name="about"
          rows="4"
          class="textarea"
          placeholder="I build software and write about the parts that are harder than they look."
        >{@voice && @voice.about}</textarea>
      </div>

      <div>
        <label class="label" for="topics">Topics</label>
        <p class="mb-2 text-[12px] text-faint">
          Comma-separated. These steer which posts SuperX learns from.
        </p>
        <input
          type="text"
          id="topics"
          name="topics"
          value={@voice && @voice.topics}
          class="input"
          placeholder="startups, writing, product design"
        />
      </div>

      <div class="flex items-center gap-6 text-xs">
        <button type="submit" class="act-key">Continue</button>
        <button type="button" phx-click="skip_voice" class="act">Skip for now</button>
      </div>
    </form>
    """
  end

  attr :presets, :list, required: true
  attr :timezones, :list, required: true
  attr :current_user, :map, required: true

  defp schedule_step(assigns) do
    ~H"""
    <h1 class="text-[1.75rem] font-semibold leading-[1.15] tracking-[-0.03em]">
      When do you want to post?
    </h1>
    <p class="mt-3 leading-[1.6] text-muted-foreground">
      Approved drafts fill the next open slot on their own. Pick a rhythm now and
      change it whenever — nothing publishes without you approving it first.
    </p>

    <form phx-change="set_timezone" class="mt-6">
      <label class="label" for="timezone">Your time zone</label>
      <select id="timezone" name="timezone" class="select">
        <option :for={tz <- @timezones} value={tz} selected={@current_user.timezone == tz}>
          {tz}
        </option>
      </select>
    </form>

    <ul class="mt-8 flex flex-col">
      <li
        :for={{key, label, slots} <- @presets}
        class="flex items-baseline gap-4 border-b border-border py-3.5 first:border-t"
      >
        <div class="flex-1">
          <p class="font-medium">{label}</p>
          <p class="nb-mono mt-0.5 text-[11px] text-faint">
            {length(slots)} posts a week · {summarise(slots)}
          </p>
        </div>
        <button phx-click="choose_preset" phx-value-preset={key} class="act-key text-xs">
          Use this
        </button>
      </li>
    </ul>

    <div class="mt-6 flex items-center gap-6 text-xs">
      <button phx-click="back" class="act">Back</button>
      <button phx-click="skip_schedule" class="act">I'll set this up later</button>
    </div>
    """
  end

  defp summarise(slots) do
    slots
    |> Enum.map(fn {_day, time} -> Calendar.strftime(time, "%H:%M") end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end
end
