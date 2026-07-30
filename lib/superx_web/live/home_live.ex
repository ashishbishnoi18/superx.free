defmodule SuperXWeb.HomeLive do
  @moduledoc """
  The daily landing screen: what's queued, what's waiting for approval,
  and whether anything needs attention.
  """

  use SuperXWeb, :live_view

  alias SuperX.{Analytics, Content}
  alias SuperX.Content.Generation

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Home") |> load()}
  end

  defp load(socket) do
    account = socket.assigns.current_x_account

    socket
    |> assign(:next_posts, Content.list_posts(account, "scheduled", limit: 3))
    |> assign(:shelf, Content.list_shelf(account, limit: 3))
    |> assign(:counts, Content.post_counts(account))
    |> assign(:shelf_total, Map.get(Content.shelf_counts(account), "all", 0))
    |> assign(:has_slots, Content.list_slots(account) != [])
    |> assign(:voice_ready, voice_ready?(account))
    |> assign(:today, Analytics.today_summary(account))
  end

  defp voice_ready?(account) do
    case Content.get_voice_profile(account) do
      %{about: about} when is_binary(about) and about != "" -> true
      _ -> false
    end
  end

  @impl true
  def handle_event("accept", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with %Generation{} = generation <- Content.get_generation(user, id),
         {:ok, post} <- Content.accept_generation(user, generation),
         {:ok, _scheduled} <- Content.schedule_post(post) do
      {:noreply, socket |> put_flash(:info, "Added to your queue.") |> load()}
    else
      {:error, :no_slots} ->
        {:noreply,
         socket
         |> put_flash(:error, "Set up some posting times first.")
         |> push_navigate(to: ~p"/settings")}

      _ ->
        {:noreply, put_flash(socket, :error, "We couldn't add that post.")}
    end
  end

  def handle_event("dismiss", %{"id" => id}, socket) do
    case Content.get_generation(socket.assigns.current_user, id) do
      nil -> {:noreply, socket}
      generation -> {:ok, _} = Content.dismiss_generation(generation); {:noreply, load(socket)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <h1 class="text-2xl font-bold tracking-tight">
          For you today
        </h1>
        <p class="mt-1 text-sm" style="color: var(--text-secondary)">
          {greeting(@current_x_account)}
        </p>
      </div>

      <.setup_checklist :if={!@voice_ready or !@has_slots} voice_ready={@voice_ready} has_slots={@has_slots} />

      <div class="grid gap-4 sm:grid-cols-3">
        <.stat label="Queued" value={@counts["scheduled"]} icon="hero-calendar-days" href={~p"/queue"} />
        <.stat label="Ready to post" value={@shelf_total} icon="hero-sparkles" href={~p"/ready-to-post"} />
        <.stat label="Published" value={@counts["posted"]} icon="hero-check-circle" href={~p"/analytics"} />
      </div>

      <section :if={@counts["failed"] > 0} class="card border-ember-200 p-4">
        <div class="flex items-start gap-3">
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-ember-600" />
          <div class="flex-1">
            <p class="font-semibold">
              {@counts["failed"]} {ngettext("post failed", "posts failed", @counts["failed"])} to publish
            </p>
            <p class="mt-0.5 text-sm" style="color: var(--text-secondary)">
              Usually an expired connection or an X rate limit. You can retry them.
            </p>
          </div>
          <.link navigate={~p"/queue?tab=failed"} class="btn btn-soft btn-sm shrink-0">Review</.link>
        </div>
      </section>

      <section class="space-y-3">
        <div class="flex items-baseline justify-between">
          <h2 class="font-semibold">Next up</h2>
          <.link navigate={~p"/queue"} class="text-sm hover:underline" style="color: var(--text-secondary)">
            View queue
          </.link>
        </div>

        <div :if={@next_posts == []} class="card p-6 text-center">
          <p class="text-sm" style="color: var(--text-secondary)">
            Nothing scheduled. Approve a draft below to fill your next slot.
          </p>
        </div>

        <div :for={post <- @next_posts} class="card card-interactive p-4">
          <div class="flex items-start gap-3">
            <Layouts.avatar src={@current_x_account.avatar_url} size="size-9" />
            <div class="min-w-0 flex-1">
              <p class="whitespace-pre-wrap text-sm leading-relaxed"><%= truncate(SuperX.Content.Post.preview_text(post), 220) %></p>
              <p class="mt-2 text-xs" style="color: var(--text-muted)">
                <.icon name="hero-clock" class="mr-1 inline size-3" />
                {format_when(post.scheduled_at, @current_user.timezone)}
              </p>
            </div>
          </div>
        </div>
      </section>

      <section class="space-y-3">
        <div class="flex items-baseline justify-between">
          <h2 class="font-semibold">Waiting for your approval</h2>
          <.link
            navigate={~p"/ready-to-post"}
            class="text-sm hover:underline"
            style="color: var(--text-secondary)"
          >
            See all
          </.link>
        </div>

        <div :if={@shelf == []} class="card p-6 text-center">
          <p class="text-sm" style="color: var(--text-secondary)">
            No drafts waiting. SuperX writes new ones overnight, or you can
            <.link navigate={~p"/ready-to-post"} class="font-medium underline">generate some now</.link>.
          </p>
        </div>

        <div :for={generation <- @shelf} class="card p-4">
          <p class="whitespace-pre-wrap text-sm leading-relaxed">{Generation.text(generation)}</p>

          <div class="mt-3 flex items-center justify-between gap-3">
            <p :if={Generation.attribution(generation)} class="text-xs" style="color: var(--text-muted)">
              <.icon name="hero-sparkles" class="mr-1 inline size-3" />
              {Generation.attribution(generation)}
            </p>
            <span :if={!Generation.attribution(generation)} />

            <div class="flex shrink-0 gap-2">
              <button phx-click="dismiss" phx-value-id={generation.id} class="btn btn-ghost btn-sm">
                Dismiss
              </button>
              <button phx-click="accept" phx-value-id={generation.id} class="btn btn-primary btn-sm">
                Add to queue
              </button>
            </div>
          </div>
        </div>
      </section>
    </div>
    """
  end

  attr :voice_ready, :boolean, required: true
  attr :has_slots, :boolean, required: true

  defp setup_checklist(assigns) do
    ~H"""
    <section class="card p-5">
      <h2 class="font-semibold">Finish setting up</h2>
      <p class="mt-1 text-sm" style="color: var(--text-secondary)">
        Two things make the drafts good rather than generic.
      </p>

      <ul class="mt-4 space-y-2.5">
        <li class="flex items-center gap-3">
          <.icon
            name={if @voice_ready, do: "hero-check-circle-solid", else: "hero-arrow-right-circle"}
            class={["size-5 shrink-0", @voice_ready && "text-ember-600"]}
          />
          <span class="flex-1 text-sm">Teach SuperX how you write</span>
          <.link :if={!@voice_ready} navigate={~p"/voice"} class="btn btn-soft btn-sm">Set up voice</.link>
        </li>
        <li class="flex items-center gap-3">
          <.icon
            name={if @has_slots, do: "hero-check-circle-solid", else: "hero-arrow-right-circle"}
            class={["size-5 shrink-0", @has_slots && "text-ember-600"]}
          />
          <span class="flex-1 text-sm">Choose when you want to post</span>
          <.link :if={!@has_slots} navigate={~p"/settings"} class="btn btn-soft btn-sm">Pick times</.link>
        </li>
      </ul>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :icon, :string, required: true
  attr :href, :string, required: true

  defp stat(assigns) do
    ~H"""
    <.link navigate={@href} class="card card-interactive p-4">
      <div class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide" style="color: var(--text-muted)">
        <.icon name={@icon} class="size-4" />
        {@label}
      </div>
      <p class="mt-2 text-3xl font-bold tabular-nums">{@value}</p>
    </.link>
    """
  end

  defp greeting(account) do
    name = account.display_name || "@#{account.handle}"
    "Here's what's happening for #{name}."
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp format_when(nil, _tz), do: ""

  defp format_when(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone, Tz.TimeZoneDatabase) do
      {:ok, local} -> Calendar.strftime(local, "%a %-d %b at %-I:%M %p")
      _ -> Calendar.strftime(datetime, "%a %-d %b at %-I:%M %p UTC")
    end
  end
end
