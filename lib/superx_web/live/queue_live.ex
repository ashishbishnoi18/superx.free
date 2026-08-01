defmodule SuperXWeb.QueueLive do
  @moduledoc """
  The publishing queue: scheduled, drafts, posted, and failed, plus the
  composer for writing and editing.
  """

  use SuperXWeb, :live_view

  alias SuperX.Content
  alias SuperX.Content.{Post, Week}

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
     |> assign(:segments, [""])
     |> load()}
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

    socket
    |> assign(:posts, Content.list_posts(account, socket.assigns.tab))
    |> assign(:counts, Content.post_counts(account))
    |> assign(:next_slot, Content.next_open_slot_at(account, socket.assigns.current_user))
    |> assign_week()
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

      post ->
        socket
        |> assign(:editing, post)
        |> assign(:segments, segments_to_text(post.segments))
    end
  end

  defp segments_to_text([]), do: [""]
  defp segments_to_text(segments), do: Enum.map(segments, &(&1["text"] || ""))

  # --- Composer ------------------------------------------------------------

  @impl true
  def handle_event("compose", _params, socket) do
    {:noreply, socket |> assign(:editing, :new) |> assign(:segments, [""])}
  end

  def handle_event("close_composer", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, nil)
     |> assign(:segments, [""])
     |> push_patch(to: ~p"/queue?tab=#{socket.assigns.tab}")}
  end

  def handle_event("update_segment", %{"index" => index, "value" => value}, socket) do
    index = String.to_integer(index)
    {:noreply, assign(socket, :segments, List.replace_at(socket.assigns.segments, index, value))}
  end

  def handle_event("add_segment", _params, socket) do
    {:noreply, assign(socket, :segments, socket.assigns.segments ++ [""])}
  end

  def handle_event("remove_segment", %{"index" => index}, socket) do
    index = String.to_integer(index)
    segments = List.delete_at(socket.assigns.segments, index)
    {:noreply, assign(socket, :segments, if(segments == [], do: [""], else: segments))}
  end

  def handle_event("save_draft", _params, socket) do
    case persist(socket, "draft") do
      {:ok, _post} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved to drafts.")
         |> assign(:editing, nil)
         |> assign(:segments, [""])
         |> assign(:tab, "draft")
         |> load()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, error_message(changeset))}
    end
  end

  def handle_event("add_to_queue", _params, socket) do
    with {:ok, post} <- persist(socket, "draft"),
         {:ok, scheduled} <- Content.schedule_post(post) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Queued for #{format_when(scheduled.scheduled_at, socket.assigns.current_user.timezone)}."
       )
       |> assign(:editing, nil)
       |> assign(:segments, [""])
       |> assign(:tab, "scheduled")
       |> load()}
    else
      {:error, :no_slots} ->
        {:noreply,
         socket
         |> put_flash(:error, "Choose some posting times first.")
         |> push_navigate(to: ~p"/settings")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, error_message(changeset))}
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

      post ->
        {:ok, _} = Content.delete_post(post)
        {:noreply, socket |> put_flash(:info, "Deleted.") |> load()}
    end
  end

  defp persist(socket, status) do
    segments = Enum.map(socket.assigns.segments, &%{"text" => &1, "media_ids" => []})
    attrs = %{segments: segments, status: status}

    case socket.assigns.editing do
      %Post{} = post ->
        Content.update_post(post, attrs)

      _ ->
        Content.create_post(
          socket.assigns.current_user,
          socket.assigns.current_x_account,
          attrs
        )
    end
  end

  # --- Render --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header title="Queue" description={queue_description(@next_slot, @current_user)}>
      <:action>
        <button phx-click="compose" class="act-key whitespace-nowrap">Create a post</button>
      </:action>
    </Layouts.page_header>

    <.composer
      :if={@editing}
      segments={@segments}
      editing={@editing}
      account={@current_x_account}
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

    <div :if={@view == "list"} class="mb-6 flex gap-6 border-b border-border">
      <.link
        :for={tab <- @tabs}
        patch={~p"/queue?tab=#{tab}"}
        class="tab"
        aria-selected={@tab == tab}
      >
        {tab_label(tab)}
        <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, tab, 0)}</span>
      </.link>
    </div>

    <div :if={@view == "list" and @posts == []} class="py-16 text-center">
      <p class="text-muted-foreground">{empty_message(@tab)}</p>
    </div>

    <div :if={@view == "list"} class="flex flex-col">
      <article
        :for={post <- @posts}
        class="grid grid-cols-1 gap-7 border-b border-border py-5 sm:grid-cols-[7.5rem_minmax(0,1fr)_auto]"
      >
        <div class="nb-mono text-[11px] leading-[1.9] text-muted-foreground">
          {format_time(post, @current_user.timezone)}
        </div>

        <div class="min-w-0">
          <%!-- A thread shows every segment, connected, rather than the
                first one and a count — you're checking what goes out, and
                the tail is where mistakes hide. --%>
          <div class="post-thread">
            <div :for={segment <- post.segments} class="post-seg">
              <div class="flex gap-2.5">
                <Layouts.avatar
                  :if={Post.thread?(post)}
                  src={@current_x_account.avatar_url}
                  size="size-6"
                  class="mt-0.5"
                />
                <p class="max-w-[58ch] whitespace-pre-wrap leading-[1.55]">{segment["text"]}</p>
              </div>
            </div>
          </div>

          <p :if={post.status == "failed"} class="mt-1.5 text-[12px] text-destructive">
            {post.error}
          </p>

          <div class="mt-3 flex flex-wrap items-center gap-5 text-xs">
            <.link
              :if={post.status in ["draft", "scheduled"]}
              patch={~p"/queue/#{post.id}"}
              class="act-key"
            >
              Edit
            </.link>
            <button
              :if={post.status == "scheduled"}
              phx-click="unschedule"
              phx-value-id={post.id}
              class="act"
            >
              Move to drafts
            </button>
            <button
              :if={post.status == "failed"}
              phx-click="retry"
              phx-value-id={post.id}
              class="act-key"
            >
              Try again
            </button>
            <a
              :if={post.permalink}
              href={post.permalink}
              target="_blank"
              rel="noopener"
              class="act"
            >
              View on 𝕏
            </a>
            <button
              :if={post.status != "posted"}
              phx-click="delete"
              phx-value-id={post.id}
              data-confirm="Delete this post?"
              class="act-danger"
            >
              Delete
            </button>
          </div>
        </div>

        <span class={["nb-mono text-[11px] tracking-[0.04em]", state_class(post.status)]}>
          {state_label(post.status)}
        </span>
      </article>
    </div>
    """
  end

  defp queue_description(nil, _user), do: "No posting times set yet — pick some under Schedule."

  defp queue_description(slot, user) do
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
  attr :account, :map, required: true

  # Composing is the one screen where you're acting *as* the account, so it
  # carries the same avatar-and-thread shape a post does — what you're
  # writing should look like what will ship.
  defp composer(assigns) do
    assigns = assign(assigns, :over, Enum.any?(assigns.segments, &(String.length(&1) > 280)))

    ~H"""
    <section class="post mb-8">
      <div class="mb-3 flex items-center justify-between">
        <span class="nb-eyebrow">
          {if is_struct(@editing), do: "Editing", else: "New post"}
        </span>
        <button phx-click="close_composer" class="act text-xs">Close</button>
      </div>

      <div class="post-thread">
        <div :for={{text, index} <- Enum.with_index(@segments)} class="post-seg">
          <div class="flex gap-2.5">
            <Layouts.avatar src={@account.avatar_url} size="size-6" class="mt-0.5" />

            <div class="min-w-0 flex-1">
              <textarea
                class="textarea"
                rows={if index == 0, do: "4", else: "3"}
                placeholder={if index == 0, do: "What's happening?", else: "Continue the thread…"}
                phx-blur="update_segment"
                phx-value-index={index}
                name="value"
              >{text}</textarea>

              <div class="mt-1.5 flex items-center justify-between">
                <.char_ring count={String.length(text)} />

                <button
                  :if={length(@segments) > 1}
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
        <button phx-click="add_to_queue" class="act-key" disabled={@over}>Add to queue</button>
        <button phx-click="save_draft" class="act">Save as draft</button>
        <button phx-click="add_segment" class="act">Continue as thread</button>
        <span :if={@over} class="ml-auto text-[11px] text-destructive">
          One post is over the limit.
        </span>
      </div>
    </section>
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

  defp error_message(other), do: inspect(other)

  defp format_when(nil, _tz), do: ""

  defp format_when(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone, Tz.TimeZoneDatabase) do
      {:ok, local} -> Calendar.strftime(local, "%a %-d %b, %-I:%M %p")
      _ -> Calendar.strftime(datetime, "%a %-d %b, %-I:%M %p UTC")
    end
  end
end
