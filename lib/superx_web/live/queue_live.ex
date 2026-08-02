defmodule SuperXWeb.QueueLive do
  @moduledoc """
  The publishing queue: scheduled, drafts, posted, and failed, plus the
  composer for writing and editing.
  """

  use SuperXWeb, :live_view

  alias SuperX.Content
  alias SuperX.Content.{Generation, Post, Slot, Week, Writer}
  alias SuperXWeb.MediaUploads

  @tabs ~w(scheduled draft posted failed)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Queue")
     |> assign(:tabs, @tabs)
     |> assign(:tab, "scheduled")
     |> assign(:view, "list")
     |> assign(:week_anchor, nil)
     |> assign(:editing, nil)
     |> assign(:composer_slot, nil)
     |> assign(:filling_slot, nil)
     |> assign(:remixing, nil)
     |> assign(:segments, [])
     |> assign(:posts, [])
     |> assign(:counts, %{})
     |> assign(:next_slot, nil)
     |> assign(:upcoming_slots, [])
     |> assign(:upcoming_slot_groups, [])
     |> assign(:unslotted_posts, [])
     |> assign(:shelf, [])
     |> assign(:week, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case socket.assigns.live_action do
        :edit -> open_editor(socket, params["id"])
        _ -> socket
      end

    tab = if params["tab"] in @tabs, do: params["tab"], else: socket.assigns.tab

    {:noreply, socket |> assign(:tab, tab) |> load()}
  end

  defp load(socket) do
    account = socket.assigns.current_x_account
    timeline = Slot.timeline(account, socket.assigns.current_user)
    upcoming_slots = timeline.occurrences

    socket
    |> assign(:posts, list_posts(account, socket.assigns.tab))
    |> assign(:counts, Content.post_counts(account))
    |> assign(:next_slot, next_opening(upcoming_slots))
    |> assign(:upcoming_slots, upcoming_slots)
    |> assign(:upcoming_slot_groups, group_slots(upcoming_slots))
    |> assign(:unslotted_posts, timeline.unslotted_posts)
    |> assign(:shelf, list_shelf(account, socket.assigns))
    |> assign_week()
  end

  defp list_posts(_account, "scheduled"), do: []
  defp list_posts(account, tab), do: Content.list_posts(account, tab)

  defp list_shelf(account, %{tab: "scheduled", view: "list"}) do
    Content.list_shelf(account, limit: 8, preload_source: false)
  end

  defp list_shelf(_account, _assigns), do: []

  defp next_opening(upcoming_slots) do
    Enum.find_value(upcoming_slots, fn
      %{post: nil, at: at} -> at
      _slot -> nil
    end)
  end

  defp group_slots(upcoming_slots) do
    upcoming_slots
    |> Enum.chunk_by(&DateTime.to_date(&1.local_at))
    |> Enum.map(fn slots ->
      date = slots |> hd() |> Map.fetch!(:local_at) |> DateTime.to_date()
      %{date: date, slots: slots}
    end)
  end

  # Only built when the calendar is on screen — it costs a query and the
  # list view never reads it.
  defp assign_week(%{assigns: %{view: "calendar"}} = socket) do
    assign(
      socket,
      :week,
      Week.build(
        socket.assigns.current_x_account,
        socket.assigns.current_user,
        socket.assigns.week_anchor
      )
    )
  end

  defp assign_week(socket), do: assign(socket, :week, nil)

  defp open_editor(socket, id) do
    case Content.get_post(socket.assigns.current_user, id) do
      nil ->
        put_flash(socket, :error, "That post no longer exists.")

      %Post{status: "failed", x_post_ids: [_ | _]} ->
        put_flash(
          socket,
          :error,
          "Part of that thread is already live. Continue it from the published post on X."
        )

      %Post{status: status} = post when status in ["draft", "scheduled", "failed"] ->
        socket
        |> assign(:editing, post)
        |> assign(:composer_slot, if(post.status == "scheduled", do: post.scheduled_at))
        |> assign(:filling_slot, nil)
        |> put_composer(post.segments)

      _post ->
        put_flash(socket, :error, "That published post can't be edited.")
    end
  end

  # --- Composer ------------------------------------------------------------

  @impl true
  def handle_event("compose", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, :new)
     |> assign(:composer_slot, nil)
     |> assign(:filling_slot, nil)
     |> put_composer([])}
  end

  def handle_event("compose_for_slot", %{"at" => encoded_at}, socket) do
    with {:ok, slot} <- find_open_slot(socket, encoded_at) do
      {:noreply,
       socket
       |> assign(:editing, :new)
       |> assign(:composer_slot, slot.at)
       |> assign(:filling_slot, nil)
       |> put_composer([])}
    else
      _ -> {:noreply, stale_slot(socket)}
    end
  end

  def handle_event("close_composer", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, nil)
     |> assign(:composer_slot, nil)
     |> assign(:segments, [])
     |> push_patch(to: ~p"/queue?tab=#{socket.assigns.tab}")}
  end

  def handle_event("update_segment", %{"index" => index, "value" => value}, socket) do
    index = String.to_integer(index)

    segments =
      List.update_at(socket.assigns.segments, index, &Map.put(&1, :text, value))

    {:noreply, assign(socket, :segments, segments)}
  end

  def handle_event("add_segment", _params, socket) do
    segment = composer_segment(%{"text" => "", "media_ids" => []})

    {:noreply,
     socket
     |> assign(:segments, socket.assigns.segments ++ [segment])
     |> allow_segment_upload(segment)}
  end

  def handle_event("remove_segment", %{"index" => index}, socket) do
    index = String.to_integer(index)
    socket = cancel_segment_uploads(socket, Enum.at(socket.assigns.segments, index))
    segments = List.delete_at(socket.assigns.segments, index)

    if segments == [] do
      {:noreply, put_composer(socket, [])}
    else
      {:noreply, assign(socket, :segments, segments)}
    end
  end

  def handle_event("remove_media", %{"index" => index, "media-id" => media_id}, socket) do
    segments =
      List.update_at(socket.assigns.segments, String.to_integer(index), fn segment ->
        Map.update!(segment, :media_ids, &List.delete(&1, media_id))
      end)

    {:noreply, assign(socket, :segments, segments)}
  end

  def handle_event("cancel_media_upload", %{"upload" => name, "ref" => ref}, socket) do
    if Enum.any?(socket.assigns.segments, &(upload_name(&1) == name)) do
      {:noreply, MediaUploads.cancel(socket, name, ref)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("media_changed", _params, socket), do: {:noreply, socket}

  def handle_event("save_draft", _params, socket) do
    {socket, result} = persist(socket, "draft")

    case result do
      {:ok, _post} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved to drafts.")
         |> assign(:editing, nil)
         |> assign(:composer_slot, nil)
         |> assign(:segments, [])
         |> assign(:tab, "draft")
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("add_to_queue", _params, socket) do
    {socket, result} = persist(socket, "draft")

    case result do
      {:ok, post} -> schedule_composed_post(socket, post)
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("choose_ready_for_slot", %{"at" => encoded_at}, socket) do
    with {:ok, slot} <- find_open_slot(socket, encoded_at) do
      {:noreply, assign(socket, :filling_slot, slot.at)}
    else
      _ -> {:noreply, stale_slot(socket)}
    end
  end

  def handle_event("close_ready_picker", _params, socket) do
    {:noreply, assign(socket, :filling_slot, nil)}
  end

  def handle_event(
        "fill_slot_from_shelf",
        %{"id" => generation_id, "at" => encoded_at},
        socket
      ) do
    with {:ok, slot} <- find_open_slot(socket, encoded_at),
         %Generation{x_account_id: account_id, status: "shelf"} = generation <-
           Content.get_generation(socket.assigns.current_user, generation_id),
         true <- account_id == socket.assigns.current_x_account.id,
         {:ok, scheduled} <-
           Content.accept_generation_into_slot(
             socket.assigns.current_user,
             generation,
             slot.at
           ) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Queued for #{format_when(scheduled.scheduled_at, socket.assigns.current_user.timezone)}."
       )
       |> assign(:filling_slot, nil)
       |> load()}
    else
      {:error, :slot_taken} ->
        {:noreply, stale_slot(socket)}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "We couldn't put that draft in the opening.")
         |> assign(:filling_slot, nil)
         |> load()}
    end
  end

  def handle_event("set_view", %{"view" => view}, socket) do
    {:noreply, socket |> assign(:view, view) |> assign(:week_anchor, nil) |> load()}
  end

  def handle_event("shift_week", %{"by" => by}, socket) do
    days = String.to_integer(by) * 7
    base = socket.assigns.week_anchor || Week.today_in(socket.assigns.current_user.timezone)

    {:noreply, socket |> assign(:week_anchor, Date.add(base, days)) |> load()}
  end

  def handle_event("this_week", _params, socket) do
    {:noreply, socket |> assign(:week_anchor, nil) |> load()}
  end

  # --- Queue actions -------------------------------------------------------

  def handle_event("remix", _params, %{assigns: %{remixing: id}} = socket)
      when not is_nil(id),
      do: {:noreply, socket}

  def handle_event("remix", %{"id" => id}, socket) do
    case Content.get_post(socket.assigns.current_user, id) do
      %Post{status: "posted"} = post ->
        parent = self()
        user = socket.assigns.current_user
        account = socket.assigns.current_x_account

        Task.Supervisor.start_child(SuperX.TaskSupervisor, fn ->
          result = Writer.remix(user, account, post)
          send(parent, {:remixed, post.id, result})
        end)

        {:noreply, assign(socket, :remixing, post.id)}

      _ ->
        {:noreply, put_flash(socket, :error, "That published post is no longer available.")}
    end
  end

  def handle_event("unschedule", %{"id" => id}, socket) do
    with %Post{} = post <- Content.get_post(socket.assigns.current_user, id),
         {:ok, _} <- Content.unschedule_post(post) do
      {:noreply, socket |> put_flash(:info, "Moved back to drafts.") |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, "We couldn't move that post.")}
    end
  end

  def handle_event("retry", %{"id" => id}, socket) do
    with %Post{} = post <- Content.get_post(socket.assigns.current_user, id),
         {:ok, _} <- Content.retry_post(post) do
      {:noreply, socket |> put_flash(:info, "Back in the queue.") |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, "We couldn't retry that post.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Content.get_post(socket.assigns.current_user, id) do
      nil ->
        {:noreply, socket}

      %Post{status: status} = post when status in ["draft", "scheduled", "failed"] ->
        {:ok, _} = Content.delete_post(post)
        {:noreply, socket |> put_flash(:info, "Deleted.") |> load()}

      _post ->
        {:noreply, put_flash(socket, :error, "That post is already being sent.")}
    end
  end

  defp schedule_composed_post(socket, post) do
    case Content.schedule_post(post, schedule_options(socket)) do
      {:ok, scheduled} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Queued for #{format_when(scheduled.scheduled_at, socket.assigns.current_user.timezone)}."
         )
         |> assign(:editing, nil)
         |> assign(:composer_slot, nil)
         |> assign(:segments, [])
         |> assign(:tab, "scheduled")
         |> load()}

      {:error, :no_slots} ->
        {:noreply,
         socket
         |> put_flash(:error, "Choose some posting times first.")
         |> push_navigate(to: ~p"/settings")}

      {:error, :slot_taken} ->
        {:noreply, socket |> assign(:editing, post) |> stale_slot()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:editing, post)
         |> put_flash(:error, error_message(changeset))}
    end
  end

  defp schedule_options(%{assigns: %{composer_slot: %DateTime{} = at}}), do: [at: at]

  defp schedule_options(%{assigns: %{editing: %Post{source: "reply"}}}) do
    [at: DateTime.utc_now() |> DateTime.truncate(:second)]
  end

  defp schedule_options(_socket), do: []

  defp find_open_slot(socket, encoded_at) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(encoded_at),
         timeline <-
           Slot.timeline(
             socket.assigns.current_x_account,
             socket.assigns.current_user
           ),
         %{} = slot <-
           Enum.find(timeline.occurrences, fn slot ->
             is_nil(slot.post) and same_instant?(slot.at, at)
           end) do
      {:ok, slot}
    else
      _ -> {:error, :not_open}
    end
  end

  defp stale_slot(socket) do
    socket
    |> assign(:filling_slot, nil)
    |> assign(:composer_slot, nil)
    |> put_flash(:error, "That opening was filled while you were choosing.")
    |> load()
  end

  defp same_instant?(%DateTime{} = left, %DateTime{} = right) do
    DateTime.compare(left, right) == :eq
  end

  defp same_instant?(_left, _right), do: false

  @impl true
  def handle_info({:remixed, _id, {:ok, _generation}}, socket) do
    send(self(), :refresh_quota)

    {:noreply,
     socket
     |> assign(:remixing, nil)
     |> put_flash(:info, "Fresh variant ready.")
     |> push_navigate(to: ~p"/ready-to-post")}
  end

  def handle_info({:remixed, _id, {:error, :quota_exceeded, _details}}, socket) do
    {:noreply,
     socket
     |> assign(:remixing, nil)
     |> put_flash(:error, "You're out of AI credits for this window.")}
  end

  def handle_info({:remixed, _id, {:error, reason}}, socket) do
    require Logger
    Logger.warning("Post remix failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:remixing, nil)
     |> put_flash(:error, "Couldn't write a fresh variant just now.")}
  end

  defp persist(socket, status) do
    {segments, errors} = consume_media(socket)
    socket = assign(socket, :segments, segments)

    result =
      case errors do
        [] -> persist_segments(socket, status)
        [reason | _] -> {:error, reason}
      end

    {socket, result}
  end

  defp persist_segments(socket, status) do
    segments =
      Enum.map(socket.assigns.segments, fn segment ->
        %{"text" => segment.text, "media_ids" => segment.media_ids}
      end)

    attrs = %{segments: segments, status: status}

    case socket.assigns.editing do
      %Post{} = post ->
        Content.update_post(post, attrs)

      _ ->
        Content.create_post(socket.assigns.current_user, socket.assigns.current_x_account, attrs)
    end
  end

  defp consume_media(socket) do
    Enum.map_reduce(socket.assigns.segments, [], fn segment, errors ->
      case MediaUploads.consume(socket, upload_name(segment)) do
        {:ok, keys} -> {%{segment | media_ids: segment.media_ids ++ keys}, errors}
        {:error, reason} -> {segment, [reason | errors]}
      end
    end)
  end

  defp put_composer(socket, stored_segments) do
    segments =
      case stored_segments do
        [] -> [composer_segment(%{"text" => "", "media_ids" => []})]
        segments -> Enum.map(segments, &composer_segment/1)
      end

    socket = assign(socket, :segments, segments)
    Enum.reduce(segments, socket, &allow_segment_upload(&2, &1))
  end

  defp composer_segment(segment) do
    %{
      id: Ecto.UUID.generate(),
      text: segment["text"] || "",
      media_ids: segment["media_ids"] || []
    }
  end

  defp allow_segment_upload(socket, segment) do
    MediaUploads.allow(socket, upload_name(segment), length(segment.media_ids))
  end

  defp upload_name(segment), do: "post_media_#{segment.id}"

  defp cancel_segment_uploads(socket, nil), do: socket

  defp cancel_segment_uploads(socket, segment) do
    upload = Map.get(socket.assigns.uploads, upload_name(segment))

    Enum.reduce(upload.entries, socket, fn entry, acc ->
      MediaUploads.cancel(acc, upload.name, entry.ref)
    end)
  end

  # --- Render --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header
      title="Queue"
      description={queue_description(@next_slot, @upcoming_slot_groups, @current_user)}
    >
      <:action>
        <button phx-click="compose" class="btn-primary whitespace-nowrap">Create a post</button>
      </:action>
    </Layouts.page_header>

    <.composer
      :if={@editing}
      segments={@segments}
      editing={@editing}
      composer_slot={@composer_slot}
      timezone={@current_user.timezone}
      account={@current_x_account}
      uploads={@uploads}
    />

    <div class="mb-5 flex items-center gap-5 text-xs">
      <button
        :for={{value, label} <- [{"list", "List"}, {"calendar", "Calendar"}]}
        phx-click="set_view"
        phx-value-view={value}
        class={if @view == value, do: "act-key", else: "act"}
      >
        {label}
      </button>

      <div :if={@view == "calendar"} class="ml-auto flex items-center gap-5">
        <button phx-click="shift_week" phx-value-by="-1" class="act">← Earlier</button>
        <button phx-click="this_week" class="nb-mono text-[11px] text-muted-foreground">
          {Week.range_label(@week.start)}
        </button>
        <button phx-click="shift_week" phx-value-by="1" class="act">Later →</button>
      </div>
    </div>

    <.calendar :if={@view == "calendar"} week={@week} />

    <div :if={@view == "list"} class="mb-9 flex gap-6 border-b border-border">
      <.link
        :for={tab <- @tabs}
        patch={~p"/queue?tab=#{tab}"}
        class="tab"
        aria-selected={to_string(@tab == tab)}
      >
        {tab_label(tab)}
        <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, tab, 0)}</span>
      </.link>
    </div>

    <section
      :if={@view == "list" and @tab == "scheduled"}
      id="queue-upcoming-slots"
      class="flex flex-col"
    >
      <div :if={@upcoming_slot_groups == []} id="queue-no-schedule" class="py-16 text-center">
        <.icon name="hero-calendar-days" class="size-6 text-faint" />
        <p class="nb-eyebrow mb-2 mt-3">Schedule</p>
        <p class="text-muted-foreground">No posting times yet.</p>
        <.link navigate={~p"/settings"} class="act-key mt-4 inline-block">
          Pick some under Schedule
        </.link>
      </div>

      <%!-- One bulk route out of an empty queue, stated once, instead of
            asking the reader to solve the same problem at every slot.
            Approving on Ready to Post fills the next opening on its own,
            so this points at the real path rather than inventing one. --%>
      <p
        :if={@shelf != [] and open_slot_count(@upcoming_slot_groups) > 0}
        id="queue-fill-hint"
        class="mb-6 flex flex-wrap items-center gap-x-2 gap-y-1 text-[13px] text-muted-foreground"
      >
        <span>
          {length(@shelf)} {if length(@shelf) == 1, do: "draft is", else: "drafts are"} ready for {open_slot_count(
            @upcoming_slot_groups
          )} open {if open_slot_count(@upcoming_slot_groups) == 1, do: "slot", else: "slots"}.
        </span>
        <.link navigate={~p"/ready-to-post"} class="act-key">Review them</.link>
      </p>

      <section
        :for={{group, index} <- Enum.with_index(@upcoming_slot_groups)}
        id={slot_group_id(group.date)}
      >
        <h2 class={[
          "flex items-baseline gap-3 border-b border-border pb-2",
          if(index == 0, do: "pt-0", else: "pt-7")
        ]}>
          <span class="nb-eyebrow text-[10px] text-foreground">
            {Calendar.strftime(group.date, "%A")}
          </span>
          <span class="nb-mono text-[11px] font-normal text-faint">
            {Calendar.strftime(group.date, "%-d %b")}
          </span>
        </h2>

        <%= for slot <- group.slots do %>
          <.post_row
            :if={slot.post}
            id={slot_id(slot)}
            post={slot.post}
            time_label={slot_time(slot)}
            account={@current_x_account}
            remixing={@remixing}
          />

          <article
            :if={is_nil(slot.post)}
            id={slot_id(slot)}
            data-slot-state="open"
            class="grid grid-cols-1 gap-4 border-b border-border py-5 sm:grid-cols-[7.5rem_minmax(0,1fr)_auto] sm:gap-7"
          >
            <div class="nb-mono text-[11px] leading-[1.9] text-muted-foreground">
              {slot_time(slot)}
            </div>

            <%!-- The sentence "Nothing is queued for this opening" used to
                  repeat once per slot, so an empty queue read as five
                  identical paragraphs. The `open` marker on the right
                  already says it, and the actions say what to do about
                  it. --%>
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-x-5 gap-y-2 text-xs">
                <button
                  id={"write-slot-#{slot_key(slot)}"}
                  phx-click="compose_for_slot"
                  phx-value-at={DateTime.to_iso8601(slot.at)}
                  class="act-key"
                >
                  <.icon name="hero-pencil-square" class="size-4" /> Write something
                </button>
                <button
                  :if={@shelf != []}
                  id={"ready-slot-#{slot_key(slot)}"}
                  phx-click="choose_ready_for_slot"
                  phx-value-at={DateTime.to_iso8601(slot.at)}
                  class="act"
                >
                  <.icon name="hero-inbox-stack" class="size-4" /> Use a ready draft
                </button>
              </div>

              <.ready_picker
                :if={same_instant?(@filling_slot, slot.at)}
                slot={slot}
                shelf={@shelf}
              />
            </div>

            <span class="nb-mono text-[11px] tracking-[0.04em] text-faint">open</span>
          </article>
        <% end %>
      </section>

      <section :if={@unslotted_posts != []} id="queue-unslotted-posts">
        <h2 class="flex items-baseline gap-3 border-b border-border pb-2 pt-7">
          <span class="nb-eyebrow text-[10px] text-foreground">Outside the schedule</span>
          <span class="text-[11px] font-normal text-faint">retries and immediate posts</span>
        </h2>

        <.post_row
          :for={post <- @unslotted_posts}
          id={"queue-post-#{post.id}"}
          post={post}
          time_label={format_time(post, @current_user.timezone)}
          account={@current_x_account}
          remixing={@remixing}
        />
      </section>
    </section>

    <div
      :if={@view == "list" and @tab != "scheduled" and @posts == []}
      id={"queue-#{@tab}-empty"}
      class="py-16 text-center"
    >
      <.icon name="hero-queue-list" class="size-6 text-faint" />
      <p class="nb-eyebrow mb-2 mt-3">{tab_label(@tab)}</p>
      <p class="text-muted-foreground">{empty_message(@tab)}</p>
    </div>

    <div :if={@view == "list" and @tab != "scheduled"} class="flex flex-col">
      <.post_row
        :for={post <- @posts}
        id={"queue-post-#{post.id}"}
        post={post}
        time_label={format_time(post, @current_user.timezone)}
        account={@current_x_account}
        remixing={@remixing}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :post, :map, required: true
  attr :time_label, :string, required: true
  attr :account, :map, required: true
  attr :remixing, :string, default: nil, doc: "id of the post currently being remixed"

  defp post_row(assigns) do
    ~H"""
    <article
      id={@id}
      data-slot-state={@post.status}
      class="grid grid-cols-1 gap-4 border-b border-border py-5 sm:grid-cols-[7.5rem_minmax(0,1fr)_auto] sm:gap-7"
    >
      <div class="nb-mono text-[11px] leading-[1.9] text-muted-foreground">
        {@time_label}
      </div>

      <div class="min-w-0">
        <%!-- Every segment is visible because the tail is where mistakes
              hide; the shared card also keeps attachment crops identical
              to the shelf and composer. --%>
        <.post author={author(@account)} segments={segments(@post)} class="max-w-[42rem]" />

        <p
          :if={@post.status == "failed"}
          id={"post-#{@post.id}-error"}
          class="mt-1.5 text-[12px] text-destructive"
        >
          {@post.error}
        </p>

        <p
          :if={@post.status == "failed" and @post.x_post_ids != []}
          id={"post-#{@post.id}-partial-help"}
          class="mt-1.5 text-[12px] text-muted-foreground"
        >
          Part of this thread is already live, so SuperX will not publish those posts twice.
          Continue it from the published part on X.
        </p>

        <div class="mt-3 flex flex-wrap items-center gap-5 text-xs">
          <.link
            :if={
              @post.status in ["draft", "scheduled"] or
                (@post.status == "failed" and @post.x_post_ids == [])
            }
            id={"edit-post-#{@post.id}"}
            patch={~p"/queue/#{@post.id}"}
            class="act-key"
          >
            Edit
          </.link>
          <button
            :if={@post.status == "scheduled"}
            phx-click="unschedule"
            phx-value-id={@post.id}
            class="act"
          >
            Move to drafts
          </button>
          <button
            :if={@post.status == "failed" and @post.x_post_ids == []}
            id={"retry-post-#{@post.id}"}
            phx-click="retry"
            phx-value-id={@post.id}
            class="act-key"
          >
            Try again
          </button>
          <a
            :if={partial_permalink(@post)}
            id={"view-published-part-#{@post.id}"}
            href={partial_permalink(@post)}
            target="_blank"
            rel="noopener"
            class="act"
          >
            View published part on 𝕏
          </a>
          <a
            :if={@post.permalink}
            href={@post.permalink}
            target="_blank"
            rel="noopener"
            class="act"
          >
            View on 𝕏
          </a>
          <button
            :if={@post.status == "posted"}
            phx-click="remix"
            phx-value-id={@post.id}
            class="act-key"
            disabled={not is_nil(@remixing)}
          >
            {if @remixing == @post.id, do: "Writing…", else: "Remix"}
          </button>
          <button
            :if={@post.status in ["draft", "scheduled", "failed"]}
            id={"delete-post-#{@post.id}"}
            phx-click="delete"
            phx-value-id={@post.id}
            data-confirm="Delete this post?"
            class="act-danger"
          >
            Delete
          </button>
        </div>
      </div>

      <span class={["nb-mono text-[11px] tracking-[0.04em]", state_class(@post.status)]}>
        {state_label(@post.status)}
      </span>
    </article>
    """
  end

  attr :slot, :map, required: true
  attr :shelf, :list, required: true

  defp ready_picker(assigns) do
    ~H"""
    <section id={"ready-picker-#{slot_key(@slot)}"} class="mt-9 border-y border-border py-4">
      <div class="mb-3 flex items-center justify-between gap-5">
        <p class="nb-eyebrow text-[10px]">Ready to Post</p>
        <button phx-click="close_ready_picker" class="act text-xs">Close</button>
      </div>

      <div
        :for={generation <- @shelf}
        id={"ready-choice-#{generation.id}"}
        class="flex items-start justify-between gap-6 border-t border-border py-3 first:border-t-0 first:pt-0 last:pb-0"
      >
        <div class="min-w-0">
          <p class="line-clamp-2 text-[13px] leading-[1.5]">
            {truncate(Generation.text(generation), 150)}
          </p>
          <p class="nb-mono mt-1 text-[10px] text-faint">{generation_label(generation.kind)}</p>
        </div>
        <button
          phx-click="fill_slot_from_shelf"
          phx-value-id={generation.id}
          phx-value-at={DateTime.to_iso8601(@slot.at)}
          class="act-key shrink-0 text-xs"
        >
          Use this draft
        </button>
      </div>
    </section>
    """
  end

  defp slot_group_id(date), do: "queue-day-#{Date.to_iso8601(date)}"
  defp slot_id(slot), do: "queue-slot-#{slot_key(slot)}"
  defp slot_key(slot), do: DateTime.to_unix(slot.at)

  defp open_slot_count(groups) do
    Enum.sum_by(groups, fn group -> Enum.count(group.slots, &is_nil(&1.post)) end)
  end

  defp slot_time(slot), do: Calendar.strftime(slot.local_at, "%-I:%M %p")

  defp generation_label(kind) do
    kind |> String.replace("_", " ") |> String.capitalize()
  end

  defp queue_description(nil, [], _user),
    do: "No posting times set yet — pick some under Schedule."

  defp queue_description(nil, _groups, _user) do
    "The next four weeks are full. New drafts will take the first opening after them."
  end

  defp queue_description(slot, _groups, user) do
    "Next opening is #{format_when(slot, user.timezone)}. Approved drafts fill it on their own."
  end

  defp state_class("posted"), do: "text-success"
  defp state_class("failed"), do: "text-destructive"
  defp state_class(_), do: "text-faint"

  defp state_label("scheduled"), do: "scheduled"
  defp state_label("posted"), do: "published"
  defp state_label("failed"), do: "failed"
  defp state_label("publishing"), do: "sending"
  defp state_label(other), do: other

  defp partial_permalink(%Post{status: "failed", x_post_ids: [first | _]}),
    do: "https://x.com/i/status/#{first}"

  defp partial_permalink(_post), do: nil

  defp format_time(%Post{status: "posted", published_at: at}, tz), do: short_when(at, tz)
  defp format_time(%Post{status: "failed", failed_at: at}, tz), do: short_when(at, tz)
  defp format_time(%Post{scheduled_at: at}, tz) when not is_nil(at), do: short_when(at, tz)
  defp format_time(_post, _tz), do: "—"

  defp short_when(nil, _tz), do: "—"

  defp short_when(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone, Tz.TimeZoneDatabase) do
      {:ok, local} -> Calendar.strftime(local, "%-d %b %H:%M")
      _ -> Calendar.strftime(datetime, "%-d %b %H:%M")
    end
  end

  attr :week, :map, required: true

  # Rows are the times the account actually posts at, not every hour — an
  # account posting twice a week gets two rows. An empty cell is a real
  # opening, which is what the view exists to show.
  defp calendar(assigns) do
    ~H"""
    <div :if={@week.rows == []} class="border-y border-border py-14 text-center">
      <.icon name="hero-calendar-days" class="size-6 text-faint" />
      <p class="nb-eyebrow mb-2 mt-3">Calendar</p>
      <p class="text-muted-foreground">
        No posting times yet. <.link navigate={~p"/settings"} class="act-key">Pick some</.link>
        and the week fills in.
      </p>
    </div>

    <div :if={@week.rows != []} class="overflow-x-auto">
      <%!-- Fixed layout: without it a filled cell widens its column and the
            week stops reading as a grid, which is the only reason to show
            it this way. --%>
      <table class="w-full min-w-[46rem] table-fixed border-collapse">
        <thead>
          <tr>
            <th class="w-14 border-b border-border pb-2 text-left"></th>
            <th
              :for={date <- @week.days}
              class="border-b border-border pb-2 text-left font-normal"
            >
              <span class={[
                "nb-eyebrow text-[10px]",
                date == @week.today && "text-primary"
              ]}>
                {Week.day_label(date)} {Calendar.strftime(date, "%-d")}
              </span>
            </th>
          </tr>
        </thead>

        <tbody>
          <tr :for={row <- @week.rows}>
            <td class="border-b border-border py-2 pr-3 align-top">
              <span class="nb-mono text-[11px] text-faint">
                {Calendar.strftime(row.time, "%H:%M")}
              </span>
            </td>

            <td
              :for={cell <- row.cells}
              class="border-b border-l border-border p-2 align-top"
            >
              <%!-- No slot on this day at this time: not an opening, just
                    outside the schedule. --%>
              <span :if={is_nil(cell.slot)} class="text-faint">·</span>

              <.link
                :if={cell.slot && cell.post}
                patch={~p"/queue/#{cell.post.id}"}
                class="hover-ember block text-[12px] leading-[1.45]"
              >
                {truncate(Post.preview_text(cell.post), 70)}
              </.link>

              <span
                :if={cell.slot && is_nil(cell.post)}
                class={[
                  "nb-mono text-[11px]",
                  if(cell.past?, do: "text-faint line-through", else: "text-muted-foreground")
                ]}
              >
                {if cell.past?, do: "missed", else: "open"}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  attr :segments, :list, required: true
  attr :editing, :any, required: true
  attr :composer_slot, :any, required: true
  attr :timezone, :string, required: true
  attr :account, :map, required: true
  attr :uploads, :map, required: true

  # Composing is the one screen where you're acting *as* the account, so it
  # carries the same avatar-and-thread shape a post does — what you're
  # writing should look like what will ship.
  defp composer(assigns) do
    assigns =
      assigns
      |> assign(:over, Enum.any?(assigns.segments, &(String.length(&1.text) > 280)))
      |> assign(
        :uploading,
        Enum.any?(assigns.segments, fn segment ->
          upload = Map.fetch!(assigns.uploads, upload_name(segment))
          Enum.any?(upload.entries, &(not &1.done?))
        end)
      )

    ~H"""
    <form id="post-composer" phx-change="media_changed" class="post mb-8">
      <div class="mb-3 flex items-center justify-between">
        <span class="nb-eyebrow">
          {if is_struct(@editing), do: "Editing", else: "New post"}
        </span>
        <span :if={@composer_slot} class="nb-mono text-[10px] text-faint">
          for {format_when(@composer_slot, @timezone)}
        </span>
        <button type="button" phx-click="close_composer" class="act text-xs">Close</button>
      </div>

      <div class="post-thread">
        <div :for={{segment, index} <- Enum.with_index(@segments)} class="post-seg">
          <div class="flex gap-2.5">
            <Layouts.avatar src={@account.avatar_url} size="size-6" class="mt-0.5" />

            <div class="min-w-0 flex-1">
              <textarea
                id={"post-segment-#{segment.id}"}
                class="textarea"
                rows={if index == 0, do: "4", else: "3"}
                placeholder={if index == 0, do: "What's happening?", else: "Continue the thread…"}
                phx-blur="update_segment"
                phx-value-index={index}
                name="value"
              >{segment.text}</textarea>

              <.post_media
                media_ids={segment.media_ids}
                upload={Map.fetch!(@uploads, upload_name(segment))}
                segment_index={index}
                remove_event="remove_media"
                cancel_event="cancel_media_upload"
              />

              <div class="mt-1.5 flex items-center justify-between">
                <.char_ring count={String.length(segment.text)} />

                <button
                  :if={length(@segments) > 1}
                  type="button"
                  phx-click="remove_segment"
                  phx-value-index={index}
                  class="act-danger text-xs"
                >
                  Remove
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="mt-4 flex flex-wrap items-center gap-5 border-t border-border pt-3 text-xs">
        <button
          id="add-post-to-queue"
          type="button"
          phx-click="add_to_queue"
          phx-disable-with="Queueing…"
          class="act-key"
          disabled={@over or @uploading}
        >
          Add to queue
        </button>
        <button
          id="save-post-draft"
          type="button"
          phx-click="save_draft"
          phx-disable-with="Saving…"
          class="act"
          disabled={@uploading}
        >
          Save as draft
        </button>
        <button type="button" phx-click="add_segment" class="act">Continue as thread</button>
        <span :if={@over} class="ml-auto text-[11px] text-destructive">
          One post is over the limit.
        </span>
      </div>
    </form>
    """
  end

  defp tab_label("draft"), do: "Drafts"
  defp tab_label(tab), do: String.capitalize(tab)

  defp empty_message("scheduled"), do: "Nothing scheduled yet."
  defp empty_message("draft"), do: "No drafts."
  defp empty_message("posted"), do: "Nothing published through SuperX yet."
  defp empty_message("failed"), do: "No failures. Good."
  defp empty_message(_), do: "Nothing here."

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp error_message(:upload_in_progress), do: "Wait for the attachment to finish uploading."
  defp error_message(:unsupported_media), do: "Use a JPEG, PNG, WebP or GIF."
  defp error_message(:too_large), do: "Each attachment must be 5 MB or smaller."
  defp error_message({:store_failed, _reason}), do: "We couldn't store that attachment."

  defp error_message(other), do: inspect(other)

  defp format_when(nil, _tz), do: ""

  defp format_when(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone, Tz.TimeZoneDatabase) do
      {:ok, local} -> Calendar.strftime(local, "%a %-d %b, %-I:%M %p")
      _ -> Calendar.strftime(datetime, "%a %-d %b, %-I:%M %p UTC")
    end
  end
end
