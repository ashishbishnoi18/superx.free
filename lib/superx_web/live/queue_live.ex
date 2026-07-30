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
    <Layouts.page_header title="Queue" description={queue_description(@next_slot, @current_user)}>
      <:action>
        <button phx-click="compose" class="act-key whitespace-nowrap">Create a post</button>
      </:action>
    </Layouts.page_header>

    <.composer :if={@editing} segments={@segments} editing={@editing} />

    <div class="mb-6 flex gap-6 border-b border-border">
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

    <div :if={@posts == []} class="py-16 text-center">
      <p class="text-muted-foreground">{empty_message(@tab)}</p>
    </div>

    <div class="flex flex-col">
      <article
        :for={post <- @posts}
        class="grid grid-cols-1 gap-7 border-b border-border py-5 sm:grid-cols-[7.5rem_minmax(0,1fr)_auto]"
      >
        <div class="nb-mono text-[11px] leading-[1.9] text-muted-foreground">
          {format_time(post, @current_user.timezone)}
          <span :if={Post.thread?(post)} class="block text-faint">
            thread · {length(post.segments)}
          </span>
        </div>

        <div class="min-w-0">
          <p class="max-w-[58ch] whitespace-pre-wrap leading-[1.55]"><%= Post.preview_text(post) %></p>

          <p :if={post.status == "failed"} class="mt-1.5 text-[12px] text-destructive">
            {post.error}
          </p>

          <div class="mt-3 flex flex-wrap items-center gap-5 text-xs">
            <.link :if={post.status in ["draft", "scheduled"]} patch={~p"/queue/#{post.id}"} class="act-key">
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
            <button :if={post.status == "failed"} phx-click="retry" phx-value-id={post.id} class="act-key">
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

  attr :segments, :list, required: true
  attr :editing, :any, required: true

  defp composer(assigns) do
    ~H"""
    <section class="mb-8 border-y border-border py-6">
      <div class="mb-4 flex items-center justify-between">
        <span class="nb-eyebrow">
          {if is_struct(@editing), do: "Editing", else: "New post"}
        </span>
        <button phx-click="close_composer" class="act text-xs">Close</button>
      </div>

      <div class="flex flex-col gap-4">
        <div :for={{text, index} <- Enum.with_index(@segments)}>
          <textarea
            class="textarea"
            rows="4"
            placeholder={if index == 0, do: "What's happening?", else: "Continue the thread…"}
            phx-blur="update_segment"
            phx-value-index={index}
            name="value"
          >{text}</textarea>

          <div class="mt-1.5 flex items-center justify-between text-[11px]">
            <span class={[
              "nb-mono",
              if(String.length(text) > 280, do: "text-destructive", else: "text-faint")
            ]}>
              {String.length(text)} / 280
            </span>

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

      <div class="mt-5 flex items-center gap-6 text-xs">
        <button phx-click="add_to_queue" class="act-key">Add to queue</button>
        <button phx-click="save_draft" class="act">Save as draft</button>
        <button phx-click="add_segment" class="act">Continue as thread</button>
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
