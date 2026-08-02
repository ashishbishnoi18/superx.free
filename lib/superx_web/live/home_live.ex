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
    counts = Content.post_counts(account)
    shelf_total = Map.get(Content.shelf_counts(account), "all", 0)
    voice_ready = voice_ready?(account)
    first_draft? = shelf_total > 0 or Enum.any?(counts, fn {_status, count} -> count > 0 end)
    first_post? = counts["scheduled"] > 0 or counts["posted"] > 0

    socket
    |> assign(:next_posts, Content.list_posts(account, "scheduled", limit: 3))
    |> assign(:shelf, Content.list_shelf(account, limit: 3))
    |> assign(:counts, counts)
    |> assign(:shelf_total, shelf_total)
    |> assign(:has_slots, Content.list_slots(account) != [])
    |> assign(:voice_ready, voice_ready)
    |> assign(:first_draft?, first_draft?)
    |> assign(:first_post?, first_post?)
    |> assign(:getting_started?, not (voice_ready and first_draft? and first_post?))
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

    account = socket.assigns.current_x_account

    with %Generation{x_account_id: account_id} = generation <- Content.get_generation(user, id),
         true <- account_id == account.id,
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
      %Generation{x_account_id: account_id} = generation
      when account_id == socket.assigns.current_x_account.id ->
        {:ok, _} = Content.dismiss_generation(generation)
        {:noreply, load(socket)}

      _generation ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header title="Today" description={greeting(@current_x_account)} />

    <section
      :if={@getting_started?}
      id="getting-started"
      class="mb-9 border-y border-border py-6"
    >
      <p class="nb-eyebrow mb-1">Start here</p>
      <p class="mb-4 max-w-[62ch] text-[12px] leading-[1.6] text-faint">
        Your dashboard fills as you complete this first publishing loop.
      </p>
      <ul class="flex flex-col gap-2.5">
        <li class="flex items-baseline gap-3">
          <span class={["nb-mono text-[11px]", @voice_ready && "text-success"]}>
            {if @voice_ready, do: "done", else: "todo"}
          </span>
          <span class="flex-1">Teach SuperX how you write</span>
          <.link :if={!@voice_ready} navigate={~p"/voice"} class="act-key text-xs">
            Set up voice
          </.link>
        </li>
        <li class="flex items-baseline gap-3">
          <span class={["nb-mono text-[11px]", @has_slots && "text-success"]}>
            {if @has_slots, do: "done", else: "todo"}
          </span>
          <span class="flex-1">Choose when you want to post</span>
          <.link :if={!@has_slots} navigate={~p"/settings"} class="act-key text-xs">Pick times</.link>
        </li>
        <li class="flex items-baseline gap-3">
          <span class={["nb-mono text-[11px]", @first_draft? && "text-success"]}>
            {if @first_draft?, do: "done", else: "todo"}
          </span>
          <span class="flex-1">Create and review your first draft</span>
          <.link
            :if={@voice_ready and !@first_draft?}
            navigate={~p"/ready-to-post"}
            class="act-key text-xs"
          >
            Create a draft
          </.link>
        </li>
        <li class="flex items-baseline gap-3">
          <span class={["nb-mono text-[11px]", @first_post? && "text-success"]}>
            {if @first_post?, do: "done", else: "todo"}
          </span>
          <span class="flex-1">Put your first approved post on the queue</span>
          <.link
            :if={@first_draft? and !@first_post?}
            navigate={~p"/ready-to-post"}
            class="act-key text-xs"
          >
            Review drafts
          </.link>
        </li>
      </ul>
    </section>

    <div class="mb-9 grid grid-cols-3 gap-px border-y border-border bg-border">
      <.link
        :for={
          {label, value, href} <- [
            {"Queued", @counts["scheduled"], ~p"/queue"},
            {"Waiting on you", @shelf_total, ~p"/ready-to-post"},
            {"Published", @counts["posted"], ~p"/analytics"}
          ]
        }
        navigate={href}
        class="group bg-background px-5 py-4"
      >
        <p class="text-[11px] text-faint">{label}</p>
        <p class="nb-display mt-1 text-[1.875rem] font-semibold leading-[1.1] tracking-[-0.035em] tabular-nums group-hover:text-primary">
          {value}
        </p>
      </.link>
    </div>

    <div class="space-y-10">
      <section :if={@counts["failed"] > 0}>
        <div class="flex items-baseline justify-between gap-4">
          <p>
            <span class="nb-mono text-[11px] text-destructive">failed</span>
            <span class="ml-3">
              {@counts["failed"]} {ngettext("post", "posts", @counts["failed"])} didn't publish.
              Usually an expired connection or a rate limit.
            </span>
          </p>
          <.link navigate={~p"/queue?tab=failed"} class="act-key shrink-0 text-xs">Review</.link>
        </div>
      </section>

      <section>
        <div class="mb-1 flex items-baseline justify-between">
          <h2 class="nb-eyebrow">Next up</h2>
          <.link navigate={~p"/queue"} class="act text-xs">Full queue</.link>
        </div>

        <p :if={@next_posts == []} class="py-6 text-muted-foreground">
          <%= if @first_draft? do %>
            Nothing scheduled. Approve a draft below to fill your next opening.
          <% else %>
            Nothing scheduled yet. Complete the first-draft step above to fill your next opening.
          <% end %>
        </p>

        <div class="flex flex-col">
          <div
            :for={post <- @next_posts}
            class="grid grid-cols-1 gap-7 border-t border-border py-4 last:border-b sm:grid-cols-[7.5rem_minmax(0,1fr)]"
          >
            <span class="nb-mono text-[11px] text-muted-foreground">
              {short_when(post.scheduled_at, @current_user.timezone)}
            </span>
            <%!-- pre-wrap prints the template's own whitespace, so the tag
                  closes onto the value and the formatter is told to leave
                  it alone. See the note in PostComponents.post/1. --%>
            <p class="max-w-[58ch] whitespace-pre-wrap leading-[1.55]" phx-no-format>{truncate(SuperX.Content.Post.preview_text(post), 220)}</p>
          </div>
        </div>
      </section>

      <section>
        <div class="mb-1 flex items-baseline justify-between">
          <h2 class="nb-eyebrow">Waiting on you</h2>
          <.link navigate={~p"/ready-to-post"} class="act text-xs">See all</.link>
        </div>

        <div :if={@shelf == []} id="home-shelf-empty" class="py-6 text-muted-foreground">
          <%= if @voice_ready do %>
            <p>No drafts waiting. Create one now, or SuperX will write new ones overnight.</p>
            <.link navigate={~p"/ready-to-post"} class="act-key mt-3 inline-block text-xs">
              Create a draft
            </.link>
          <% else %>
            <p>
              No drafts can be written yet. Set up your voice first so they sound like you.
            </p>
            <.link navigate={~p"/voice"} class="act-key mt-3 inline-block text-xs">
              Set up voice
            </.link>
          <% end %>
        </div>

        <div class="mt-3 flex flex-col gap-3">
          <.post
            :for={generation <- @shelf}
            author={author(@current_x_account)}
            segments={segments(generation)}
          >
            <:meta>{Generation.attribution(generation) || ago(generation.inserted_at)}</:meta>

            <:actions>
              <button phx-click="accept" phx-value-id={generation.id} class="act-key">
                <.icon name="hero-plus-circle" class="size-4" /> Add to queue
              </button>
              <button phx-click="dismiss" phx-value-id={generation.id} class="act-danger">
                <.icon name="hero-no-symbol" class="size-4" /> Discard
              </button>
            </:actions>
          </.post>
        </div>
      </section>
    </div>
    """
  end

  defp greeting(account) do
    name = account.display_name || "@#{account.handle}"
    "Here's what's happening for #{name}."
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  # Matches the Queue's format — the same datum should not be written two
  # ways in one app.
  defp short_when(nil, _tz), do: "—"

  defp short_when(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone, Tz.TimeZoneDatabase) do
      {:ok, local} -> Calendar.strftime(local, "%-d %b %H:%M")
      _ -> Calendar.strftime(datetime, "%-d %b %H:%M")
    end
  end
end
