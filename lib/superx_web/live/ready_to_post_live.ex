defmodule SuperXWeb.ReadyToPostLive do
  @moduledoc """
  The approval shelf: AI-written posts waiting to be queued, edited, or
  discarded.
  """

  use SuperXWeb, :live_view

  alias SuperX.Content
  alias SuperX.Content.{Generation, Writer}

  @impl true
  def mount(_params, _session, socket) do
    account = socket.assigns.current_x_account

    if connected?(socket) do
      Phoenix.PubSub.subscribe(SuperX.PubSub, "shelf:#{account.id}")
    end

    {:ok,
     socket
     |> assign(page_title: "Ready to Post")
     |> assign(:kind, nil)
     |> assign(:generating, false)
     |> assign(:ai_configured, SuperX.AI.configured?())
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    kind = if params["kind"] in Generation.kinds(), do: params["kind"]
    {:noreply, socket |> assign(:kind, kind) |> load()}
  end

  defp load(socket) do
    account = socket.assigns.current_x_account

    socket
    |> assign(:shelf, Content.list_shelf(account, kind: socket.assigns.kind))
    |> assign(:counts, Content.shelf_counts(account))
    |> assign(:voice, Content.get_voice_profile(account))
  end

  @impl true
  def handle_info(:shelf_updated, socket), do: {:noreply, load(socket)}

  def handle_info({:generated, {:ok, _generation}}, socket) do
    # Picked up by the shell hook, which repaints the credit meter.
    send(self(), :refresh_quota)

    {:noreply,
     socket
     |> assign(:generating, false)
     |> put_flash(:info, "Wrote a new draft.")
     |> load()}
  end

  def handle_info({:generated, {:error, :quota_exceeded, _details}}, socket) do
    {:noreply,
     socket
     |> assign(:generating, false)
     |> put_flash(:error, "You're out of AI credits for this window.")}
  end

  def handle_info({:generated, {:error, :no_topics}}, socket) do
    {:noreply,
     socket
     |> assign(:generating, false)
     |> put_flash(:error, "Set up your voice first so SuperX knows what to write about.")
     |> push_navigate(to: ~p"/voice")}
  end

  def handle_info({:generated, {:error, reason}}, socket) do
    require Logger
    Logger.warning("Generation failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:generating, false)
     |> put_flash(:error, "Couldn't write a draft just now. Try again in a moment.")}
  end

  @impl true
  def handle_event("generate", _params, socket) do
    user = socket.assigns.current_user
    account = socket.assigns.current_x_account
    parent = self()

    # Generation takes several seconds; don't block the LiveView on it.
    Task.Supervisor.start_child(SuperX.TaskSupervisor, fn ->
      send(parent, {:generated, Writer.generate(user, account, kind: socket.assigns.kind)})
    end)

    {:noreply, assign(socket, :generating, true)}
  end

  def handle_event("accept", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with %Generation{} = generation <- Content.get_generation(user, id),
         {:ok, post} <- Content.accept_generation(user, generation),
         {:ok, scheduled} <- Content.schedule_post(post) do
      {:noreply,
       socket
       |> put_flash(:info, "Queued for #{format_when(scheduled.scheduled_at, user.timezone)}.")
       |> load()}
    else
      {:error, :no_slots} ->
        {:noreply,
         socket
         |> put_flash(:error, "Choose some posting times first.")
         |> push_navigate(to: ~p"/settings")}

      _ ->
        {:noreply, put_flash(socket, :error, "We couldn't queue that post.")}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with %Generation{} = generation <- Content.get_generation(user, id),
         {:ok, post} <- Content.accept_generation(user, generation) do
      {:noreply, push_navigate(socket, to: ~p"/queue/#{post.id}")}
    else
      _ -> {:noreply, put_flash(socket, :error, "We couldn't open that draft.")}
    end
  end

  def handle_event("dismiss", %{"id" => id}, socket) do
    case Content.get_generation(socket.assigns.current_user, id) do
      nil ->
        {:noreply, socket}

      generation ->
        {:ok, _} = Content.dismiss_generation(generation)
        {:noreply, load(socket)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold tracking-tight">Ready to Post</h1>
          <p class="mt-1 text-sm" style="color: var(--text-secondary)">
            Drafts written in your voice, built on posts that already worked.
          </p>
        </div>

        <button
          :if={@ai_configured}
          phx-click="generate"
          disabled={@generating}
          class="btn btn-secondary shrink-0"
        >
          <.icon
            name={if @generating, do: "hero-arrow-path", else: "hero-sparkles"}
            class={["size-4", @generating && "animate-spin"]}
          />
          {if @generating, do: "Writing…", else: "Write another"}
        </button>
      </div>

      <div :if={!@ai_configured} class="card p-4 text-sm">
        <p class="font-semibold">No LLM configured</p>
        <p class="mt-1" style="color: var(--text-secondary)">
          Set <code class="font-mono text-xs">ANTHROPIC_API_KEY</code> to generate drafts.
        </p>
      </div>

      <div class="flex gap-5 border-b" style="border-color: var(--border-subtle)">
        <.link patch={~p"/ready-to-post"} class="tab" aria-selected={is_nil(@kind)}>
          All <span class="ml-1 text-xs opacity-60">{Map.get(@counts, "all", 0)}</span>
        </.link>
        <.link
          :for={kind <- ["for_you", "trending", "viral"]}
          patch={~p"/ready-to-post?kind=#{kind}"}
          class="tab"
          aria-selected={@kind == kind}
        >
          {label_for(kind)}
          <span class="ml-1 text-xs opacity-60">{Map.get(@counts, kind, 0)}</span>
        </.link>
      </div>

      <div :if={@shelf == []} class="card p-10 text-center">
        <.icon name="hero-sparkles" class="mx-auto size-8" style="color: var(--text-muted)" />
        <p class="mt-3 font-semibold">Nothing on the shelf</p>
        <p class="mx-auto mt-1 max-w-sm text-sm" style="color: var(--text-secondary)">
          <span :if={!@voice || !@voice.about}>
            Set up your voice and SuperX will start writing drafts overnight.
          </span>
          <span :if={@voice && @voice.about}>
            SuperX refills this overnight, or write one now.
          </span>
        </p>
        <.link :if={!@voice || !@voice.about} navigate={~p"/voice"} class="btn btn-primary mt-5">
          Set up voice
        </.link>
      </div>

      <div class="columns-1 gap-4 lg:columns-2 [&>*]:mb-4">
        <article :for={generation <- @shelf} class="card card-interactive break-inside-avoid p-4">
          <div class="flex items-start gap-2.5">
            <Layouts.avatar src={@current_x_account.avatar_url} size="size-9" />
            <div class="min-w-0 flex-1">
              <p class="text-sm font-semibold">
                {@current_x_account.display_name}
                <span class="font-normal" style="color: var(--text-muted)">
                  @{@current_x_account.handle}
                </span>
              </p>
              <p class="mt-1 whitespace-pre-wrap text-[0.9375rem] leading-relaxed"><%= Generation.text(generation) %></p>
            </div>
          </div>

          <div class="mt-3 flex flex-wrap items-center justify-between gap-2">
            <p
              :if={Generation.attribution(generation)}
              class="text-xs"
              style="color: var(--text-muted)"
            >
              <.icon name="hero-sparkles" class="mr-0.5 inline size-3" />
              {Generation.attribution(generation)}
            </p>
            <span :if={!Generation.attribution(generation)} />

            <div class="flex shrink-0 items-center gap-1.5">
              <button
                phx-click="dismiss"
                phx-value-id={generation.id}
                class="btn btn-ghost btn-sm"
                title="Dismiss"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
              <button phx-click="edit" phx-value-id={generation.id} class="btn btn-secondary btn-sm">
                Edit
              </button>
              <button phx-click="accept" phx-value-id={generation.id} class="btn btn-primary btn-sm">
                Add to queue
              </button>
            </div>
          </div>
        </article>
      </div>
    </div>
    """
  end

  defp label_for("for_you"), do: "For you"
  defp label_for("trending"), do: "Trending"
  defp label_for("viral"), do: "Viral"
  defp label_for(other), do: String.capitalize(other)

  defp format_when(nil, _tz), do: "later"

  defp format_when(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone, Tz.TimeZoneDatabase) do
      {:ok, local} -> Calendar.strftime(local, "%a %-d %b, %-I:%M %p")
      _ -> Calendar.strftime(datetime, "%a %-d %b, %-I:%M %p UTC")
    end
  end
end
