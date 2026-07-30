defmodule SuperXWeb.QueueLive do
  @moduledoc """
  The publishing queue: scheduled, drafts, posted, and failed, plus the
  composer for writing and editing.
  """

  use SuperXWeb, :live_view

  alias SuperX.Content
  alias SuperX.Content.Post

  @tabs ~w(scheduled draft posted failed)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Queue")
     |> assign(:tabs, @tabs)
     |> assign(:tab, "scheduled")
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
  end

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
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold tracking-tight">Queue</h1>
          <p class="mt-1 text-sm" style="color: var(--text-secondary)">
            <span :if={@next_slot}>
              Next open slot {format_when(@next_slot, @current_user.timezone)}.
            </span>
            <span :if={!@next_slot}>
              No posting times set —
              <.link navigate={~p"/settings"} class="underline">choose some</.link>.
            </span>
          </p>
        </div>

        <button phx-click="compose" class="btn btn-primary shrink-0">
          <.icon name="hero-pencil-square" class="size-4" /> Create a post
        </button>
      </div>

      <.composer :if={@editing} segments={@segments} account={@current_x_account} editing={@editing} />

      <div class="flex gap-5 border-b" style="border-color: var(--border-subtle)">
        <.link
          :for={tab <- @tabs}
          patch={~p"/queue?tab=#{tab}"}
          class="tab"
          aria-selected={@tab == tab}
        >
          {tab_label(tab)}
          <span class="ml-1 text-xs opacity-60">{Map.get(@counts, tab, 0)}</span>
        </.link>
      </div>

      <div :if={@posts == []} class="card p-10 text-center">
        <p class="text-sm" style="color: var(--text-secondary)">{empty_message(@tab)}</p>
      </div>

      <div class="space-y-3">
        <article :for={post <- @posts} class="card p-4">
          <div class="flex items-start gap-3">
            <Layouts.avatar src={@current_x_account.avatar_url} size="size-9" />

            <div class="min-w-0 flex-1">
              <p class="whitespace-pre-wrap text-[0.9375rem] leading-relaxed"><%= Post.preview_text(post) %></p>

              <p :if={Post.thread?(post)} class="mt-1.5 text-xs" style="color: var(--text-muted)">
                <.icon name="hero-bars-3-bottom-left" class="mr-0.5 inline size-3" />
                Thread of {length(post.segments)}
              </p>

              <p class="mt-2 text-xs" style="color: var(--text-muted)">
                <span :if={post.status == "scheduled"}>
                  <.icon name="hero-clock" class="mr-0.5 inline size-3" />
                  {format_when(post.scheduled_at, @current_user.timezone)}
                </span>
                <span :if={post.status == "posted"}>
                  <.icon name="hero-check-circle" class="mr-0.5 inline size-3" />
                  Published {format_when(post.published_at, @current_user.timezone)}
                  <a
                    :if={post.permalink}
                    href={post.permalink}
                    target="_blank"
                    rel="noopener"
                    class="ml-1 underline"
                  >
                    View on 𝕏
                  </a>
                </span>
                <span :if={post.status == "failed"} class="text-ember-600">
                  <.icon name="hero-exclamation-triangle" class="mr-0.5 inline size-3" />
                  {post.error}
                </span>
              </p>
            </div>

            <div class="flex shrink-0 items-center gap-1.5">
              <.link
                :if={post.status in ["draft", "scheduled"]}
                patch={~p"/queue/#{post.id}"}
                class="btn btn-ghost btn-sm"
                title="Edit"
              >
                <.icon name="hero-pencil" class="size-4" />
              </.link>
              <button
                :if={post.status == "scheduled"}
                phx-click="unschedule"
                phx-value-id={post.id}
                class="btn btn-secondary btn-sm"
              >
                Unschedule
              </button>
              <button
                :if={post.status == "failed"}
                phx-click="retry"
                phx-value-id={post.id}
                class="btn btn-soft btn-sm"
              >
                Retry
              </button>
              <button
                :if={post.status != "posted"}
                phx-click="delete"
                phx-value-id={post.id}
                data-confirm="Delete this post?"
                class="btn btn-ghost btn-sm"
                title="Delete"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </div>
        </article>
      </div>
    </div>
    """
  end

  attr :segments, :list, required: true
  attr :account, :map, required: true
  attr :editing, :any, required: true

  defp composer(assigns) do
    ~H"""
    <section class="card p-4">
      <div class="mb-3 flex items-center justify-between">
        <p class="text-sm font-semibold">
          {if is_struct(@editing), do: "Edit post", else: "New post"}
        </p>
        <button phx-click="close_composer" class="btn btn-ghost btn-sm" title="Close">
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <div class="space-y-3">
        <div :for={{text, index} <- Enum.with_index(@segments)} class="flex items-start gap-3">
          <Layouts.avatar src={@account.avatar_url} size="size-9" />

          <div class="min-w-0 flex-1">
            <textarea
              class="textarea"
              rows="3"
              placeholder={if index == 0, do: "What's happening?", else: "Continue the thread…"}
              phx-blur="update_segment"
              phx-value-index={index}
              name="value"
            >{text}</textarea>

            <div class="mt-1 flex items-center justify-between">
              <span
                class={[
                  "text-xs tabular-nums",
                  String.length(text) > 280 && "font-semibold text-ember-600"
                ]}
                style={String.length(text) <= 280 && "color: var(--text-muted)"}
              >
                {String.length(text)}/280
              </span>

              <button
                :if={length(@segments) > 1}
                phx-click="remove_segment"
                phx-value-index={index}
                class="btn btn-ghost btn-sm"
                title="Remove"
              >
                <.icon name="hero-minus-circle" class="size-4" />
              </button>
            </div>
          </div>
        </div>
      </div>

      <div class="mt-3 flex items-center justify-between gap-3">
        <button phx-click="add_segment" class="btn btn-ghost btn-sm">
          <.icon name="hero-plus" class="size-4" /> Add to thread
        </button>

        <div class="flex gap-2">
          <button phx-click="save_draft" class="btn btn-secondary">Save draft</button>
          <button phx-click="add_to_queue" class="btn btn-primary">Add to queue</button>
        </div>
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
