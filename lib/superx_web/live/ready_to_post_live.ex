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
    <Layouts.page_header
      title="Ready to Post"
      description="Drafts written in your voice, each built on the shape of a post that already worked. Nothing goes out until you say so."
    >
      <:action>
        <button
          :if={@ai_configured}
          phx-click="generate"
          disabled={@generating}
          class="act-key whitespace-nowrap"
        >
          {if @generating, do: "Writing…", else: "Write another"}
        </button>
      </:action>
    </Layouts.page_header>

    <p :if={!@ai_configured} class="mb-8 text-muted-foreground">
      Set <code class="nb-mono text-[12px] text-foreground">ANTHROPIC_API_KEY</code>
      to have SuperX write drafts for you. You can still write your own.
    </p>

    <div class="mb-6 flex gap-6 border-b border-border">
      <.link patch={~p"/ready-to-post"} class="tab" aria-selected={is_nil(@kind)}>
        All <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, "all", 0)}</span>
      </.link>
      <.link
        :for={kind <- ["for_you", "trending", "viral"]}
        patch={~p"/ready-to-post?kind=#{kind}"}
        class="tab"
        aria-selected={@kind == kind}
      >
        {label_for(kind)}
        <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, kind, 0)}</span>
      </.link>
    </div>

    <div :if={@shelf == []} class="py-16 text-center">
      <p class="text-muted-foreground">
        <span :if={!@voice || !@voice.about}>
          Nothing here yet. Teach SuperX how you write and it starts drafting overnight.
        </span>
        <span :if={@voice && @voice.about}>
          Nothing waiting. SuperX refills this overnight.
        </span>
      </p>
      <.link :if={!@voice || !@voice.about} navigate={~p"/voice"} class="act-key mt-4 inline-block">
        Set up your voice
      </.link>
    </div>

    <%!-- Drafts are shown as the post they'd become, under the account
          that would publish it — approving is a judgement about how it
          will read on X, not about a row in our database. --%>
    <div class="columns-1 gap-4 lg:columns-2 [&>*]:mb-4">
      <.post
        :for={generation <- @shelf}
        author={author(@current_x_account)}
        segments={segments(generation)}
        class="break-inside-avoid"
      >
        <%!-- The attribution is itself the reference to the source, so it
              carries the link rather than duplicating it as an action. --%>
        <:meta>
          <a
            :if={generation.source_corpus_post}
            href={corpus_url(generation.source_corpus_post)}
            target="_blank"
            rel="noopener"
            class="hover-ember"
          >
            {Generation.attribution(generation)}
          </a>
          <span :if={!generation.source_corpus_post}>{ago(generation.inserted_at)}</span>
        </:meta>

        <:actions>
          <button phx-click="accept" phx-value-id={generation.id} class="act-key">
            Add to queue
          </button>
          <button phx-click="edit" phx-value-id={generation.id} class="act">Edit</button>
          <button phx-click="dismiss" phx-value-id={generation.id} class="act-danger">
            Discard
          </button>
        </:actions>
      </.post>
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
