defmodule SuperXWeb.ReadyToPostLive do
  @moduledoc """
  The approval shelf: AI-written posts waiting to be queued, edited, or
  discarded.
  """

  use SuperXWeb, :live_view

  alias SuperX.Content
  alias SuperX.Content.{Generation, Writer}
  alias SuperX.Workers
  alias SuperXWeb.MediaUploads

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

    shelf = Content.list_shelf(account, kind: socket.assigns.kind)

    socket
    |> assign(:shelf, shelf)
    |> assign(:counts, Content.shelf_counts(account))
    |> assign(:voice, Content.get_voice_profile(account))
    |> assign(:refill_state, refill_state(account))
    |> allow_shelf_uploads(shelf)
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

    with {:ok, socket, generation} <- prepare_generation(socket, id),
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

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, media_error(reason, "queue"))}

      _reason ->
        {:noreply, put_flash(socket, :error, "We couldn't queue that post.")}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, socket, generation} <- prepare_generation(socket, id),
         {:ok, post} <- Content.accept_generation(user, generation) do
      {:noreply, push_navigate(socket, to: ~p"/queue/#{post.id}")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, media_error(reason, "open"))}

      _reason ->
        {:noreply, put_flash(socket, :error, "We couldn't open that draft.")}
    end
  end

  def handle_event("media_changed", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_shelf_upload", %{"upload" => name, "ref" => ref}, socket) do
    {:noreply, MediaUploads.cancel(socket, name, ref)}
  end

  def handle_event(
        "remove_shelf_media",
        %{"owner" => id, "index" => index, "media-id" => media_id},
        socket
      ) do
    with %Generation{} = generation <- Content.get_generation(socket.assigns.current_user, id),
         segments <- remove_generation_media(generation.segments, index, media_id),
         {:ok, _generation} <- Content.update_generation(generation, %{segments: segments}) do
      {:noreply, load(socket)}
    else
      _reason -> {:noreply, put_flash(socket, :error, "We couldn't remove that attachment.")}
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
          :if={@ai_configured and @kind in [nil, "for_you"]}
          id="write-another"
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

    <div class="mb-9 flex gap-6 border-b border-border">
      <.link patch={~p"/ready-to-post"} class="tab" aria-selected={to_string(is_nil(@kind))}>
        All <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, "all", 0)}</span>
      </.link>
      <.link
        :for={kind <- ["for_you", "products", "trending", "viral"]}
        patch={~p"/ready-to-post?kind=#{kind}"}
        class="tab"
        aria-selected={to_string(@kind == kind)}
      >
        {label_for(kind)}
        <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, kind, 0)}</span>
      </.link>
    </div>

    <div :if={@shelf == []} id="shelf-empty" class="py-16 text-center">
      <%= cond do %>
        <% @generating -> %>
          <p id="shelf-writing-empty" class="text-muted-foreground">
            Writing your draft now…
          </p>
        <% Map.get(@counts, "all", 0) > 0 -> %>
          <p id="shelf-filter-empty" class="text-muted-foreground">
            No {label_for(@kind)} drafts are waiting.
          </p>
          <.link patch={~p"/ready-to-post"} class="act mt-4 inline-block">View all drafts</.link>
        <% @refill_state == :manual_workers -> %>
          <p id="shelf-manual-workers-empty" class="text-muted-foreground">
            No drafts waiting. Your workers only run when you press Run now.
          </p>
          <.link id="run-a-worker" navigate={~p"/workers"} class="act-key mt-4 inline-block">
            Run a worker
          </.link>
        <% (!@voice || !@voice.about) and @refill_state == :scheduled_workers -> %>
          <p id="shelf-scheduled-voice-empty" class="text-muted-foreground">
            Nothing here yet. Set up your voice before your scheduled workers run.
          </p>
          <.link navigate={~p"/voice"} class="act-key mt-4 inline-block">
            Set up your voice
          </.link>
        <% !@voice || !@voice.about -> %>
          <p id="shelf-voice-empty" class="text-muted-foreground">
            Nothing here yet. Teach SuperX how you write and it starts drafting overnight.
          </p>
          <.link navigate={~p"/voice"} class="act-key mt-4 inline-block">
            Set up your voice
          </.link>
        <% @refill_state == :scheduled_workers -> %>
          <p id="shelf-scheduled-workers-empty" class="text-muted-foreground">
            No drafts waiting. Your workers will add their next scheduled batches here.
          </p>
          <.link navigate={~p"/workers"} class="act mt-4 inline-block">View workers</.link>
        <% true -> %>
          <p id="shelf-overnight-empty" class="text-muted-foreground">
            Nothing waiting. SuperX refills this overnight.
          </p>
      <% end %>
    </div>

    <%!-- Drafts are shown as the post they'd become, under the account
          that would publish it — approving is a judgement about how it
          will read on X, not about a row in our database. --%>
    <div class="columns-1 gap-4 lg:columns-2 [&>*]:mb-4">
      <form
        :for={generation <- @shelf}
        id={"shelf-media-#{generation.id}"}
        phx-change="media_changed"
        class="break-inside-avoid"
      >
        <.post
          author={author(@current_x_account)}
          segments={segments(generation)}
          media_uploads={shelf_uploads(@uploads, generation)}
          media_owner_id={generation.id}
          media_remove_event="remove_shelf_media"
          media_cancel_event="cancel_shelf_upload"
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
            <button
              type="button"
              phx-click="accept"
              phx-value-id={generation.id}
              class="act-key"
              disabled={generation_uploading?(@uploads, generation)}
            >
              <.icon name="hero-plus-circle" class="size-4" /> Add to queue
            </button>
            <button
              type="button"
              phx-click="edit"
              phx-value-id={generation.id}
              class="act"
              disabled={generation_uploading?(@uploads, generation)}
            >
              <.icon name="hero-pencil-square" class="size-4" /> Edit
            </button>
            <button
              type="button"
              phx-click="dismiss"
              phx-value-id={generation.id}
              class="act-danger"
            >
              <.icon name="hero-no-symbol" class="size-4" /> Discard
            </button>
          </:actions>
        </.post>
      </form>
    </div>
    """
  end

  defp label_for("for_you"), do: "For you"
  defp label_for("products"), do: "Products"
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

  defp refill_state(account) do
    case Workers.list_content_workers(account) do
      [] ->
        :overnight

      workers ->
        if Enum.any?(workers, &(&1.enabled and &1.cadence in ["daily", "weekly"])) do
          :scheduled_workers
        else
          # Any configured worker disables the legacy nightly top-up. When
          # none has a live schedule, promising an overnight refill makes an
          # intentionally on-demand shelf look broken the following morning.
          :manual_workers
        end
    end
  end

  defp allow_shelf_uploads(socket, shelf) do
    Enum.reduce(shelf, socket, fn generation, acc ->
      generation.segments
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {segment, index}, inner ->
        MediaUploads.allow(
          inner,
          shelf_upload_name(generation, index),
          length(segment["media_ids"] || [])
        )
      end)
    end)
  end

  defp shelf_uploads(uploads, generation) do
    generation.segments
    |> Enum.with_index()
    |> Map.new(fn {_segment, index} ->
      {index, Map.fetch!(uploads, shelf_upload_name(generation, index))}
    end)
  end

  defp generation_uploading?(uploads, generation) do
    generation.segments
    |> Enum.with_index()
    |> Enum.any?(fn {_segment, index} ->
      upload = Map.fetch!(uploads, shelf_upload_name(generation, index))
      Enum.any?(upload.entries, &(not &1.done?))
    end)
  end

  defp prepare_generation(socket, id) do
    case Content.get_generation(socket.assigns.current_user, id) do
      %Generation{} = generation -> consume_generation_media(socket, generation)
      nil -> {:error, :not_found}
    end
  end

  defp consume_generation_media(socket, generation) do
    {segments, errors} =
      generation.segments
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {segment, index}, errors ->
        case MediaUploads.consume(socket, shelf_upload_name(generation, index)) do
          {:ok, keys} ->
            media_ids = (segment["media_ids"] || []) ++ keys
            {Map.put(segment, "media_ids", media_ids), errors}

          {:error, reason} ->
            {segment, [reason | errors]}
        end
      end)

    case errors do
      [] ->
        case Content.update_generation(generation, %{segments: segments}) do
          {:ok, generation} -> {:ok, socket, generation}
          {:error, reason} -> {:error, reason}
        end

      [reason | _] ->
        {:error, reason}
    end
  end

  defp remove_generation_media(segments, index, media_id) do
    List.update_at(segments, String.to_integer(index), fn segment ->
      Map.update(segment, "media_ids", [], &List.delete(&1, media_id))
    end)
  end

  defp shelf_upload_name(generation, index), do: "shelf_media_#{generation.id}_#{index}"

  defp media_error(:upload_in_progress, _action),
    do: "Wait for the attachment to finish uploading."

  defp media_error(:unsupported_media, _action), do: "Use a JPEG, PNG, WebP or GIF."
  defp media_error(:too_large, _action), do: "Each attachment must be 5 MB or smaller."
  defp media_error({:store_failed, _reason}, _action), do: "We couldn't store that attachment."
  defp media_error(_reason, "queue"), do: "We couldn't queue that post."
  defp media_error(_reason, "open"), do: "We couldn't open that draft."
end
