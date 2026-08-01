defmodule SuperXWeb.EngageLive do
  @moduledoc """
  The engagement inbox: mentions, replies, and topic feeds, ordered by what
  is actually worth answering.
  """

  use SuperXWeb, :live_view

  alias SuperX.Content
  alias SuperX.Engage
  alias SuperX.Engage.{Engagement, Feed, Replier}

  @kinds ~w(mention feed)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Engage")
     |> assign(:kind, nil)
     |> assign(:drafting, MapSet.new())
     |> assign(:ai_configured, SuperX.AI.configured?())
     |> assign(:api_configured, SuperX.TwitterAPI.configured?())
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    kind = if params["kind"] in @kinds, do: params["kind"]
    {:noreply, socket |> assign(:kind, kind) |> load()}
  end

  defp load(socket) do
    account = socket.assigns.current_x_account

    socket
    |> assign(:engagements, Engage.list_engagements(account, kind: socket.assigns.kind))
    |> assign(:counts, Engage.counts(account))
    |> assign(:feeds, Engage.list_feeds(account))
  end

  # --- Replying ------------------------------------------------------------

  @impl true
  def handle_event("draft", %{"id" => id}, socket) do
    account = socket.assigns.current_x_account
    user = socket.assigns.current_user

    case Engage.get_engagement(account, id) do
      nil ->
        {:noreply, socket}

      engagement ->
        parent = self()

        Task.Supervisor.start_child(SuperX.TaskSupervisor, fn ->
          send(parent, {:drafted, id, Replier.draft(user, account, engagement)})
        end)

        {:noreply, update(socket, :drafting, &MapSet.put(&1, id))}
    end
  end

  def handle_event("send", %{"draft_id" => draft_id}, socket) do
    user = socket.assigns.current_user
    account = socket.assigns.current_x_account

    with %{} = draft <- Engage.get_draft(user, draft_id),
         {:ok, post} <-
           Content.create_post(user, account, %{
             segments: [%{"text" => draft.text, "media_ids" => []}],
             status: "draft",
             source: "reply",
             reply_to_x_post_id: draft.engagement.x_post_id
           }),
         # Replies go out now rather than into a queue slot — a reply two
         # days late is not a reply.
         {:ok, _scheduled} <-
           Content.schedule_post(post, at: DateTime.utc_now() |> DateTime.truncate(:second)),
         {:ok, _} <- Engage.use_draft(draft),
         {:ok, _} <- Engage.mark_replied(draft.engagement, post.id) do
      {:noreply, socket |> put_flash(:info, "Reply queued to send.") |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, "We couldn't send that reply.")}
    end
  end

  def handle_event("dismiss_draft", %{"draft_id" => draft_id}, socket) do
    case Engage.get_draft(socket.assigns.current_user, draft_id) do
      nil ->
        {:noreply, socket}

      draft ->
        {:ok, _} = Engage.dismiss_draft(draft)
        {:noreply, load(socket)}
    end
  end

  def handle_event("ignore", %{"id" => id}, socket) do
    case Engage.get_engagement(socket.assigns.current_x_account, id) do
      nil ->
        {:noreply, socket}

      engagement ->
        {:ok, _} = Engage.ignore(engagement)
        {:noreply, load(socket)}
    end
  end

  # --- Feeds ---------------------------------------------------------------

  def handle_event("add_feed", %{"query" => query} = params, socket) do
    attrs = %{query: String.trim(query), name: params["name"], min_likes: 50}

    case Engage.create_feed(socket.assigns.current_x_account, attrs) do
      {:ok, _feed} -> {:noreply, socket |> put_flash(:info, "Feed added.") |> load()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "That feed already exists.")}
    end
  end

  def handle_event("add_suggested", %{"query" => query, "name" => name}, socket) do
    Engage.create_feed(socket.assigns.current_x_account, %{
      query: query,
      name: name,
      min_likes: 30
    })

    {:noreply, load(socket)}
  end

  def handle_event("toggle_feed", %{"id" => id}, socket) do
    Engage.toggle_feed(socket.assigns.current_x_account, id)
    {:noreply, load(socket)}
  end

  def handle_event("delete_feed", %{"id" => id}, socket) do
    Engage.delete_feed(socket.assigns.current_x_account, id)
    {:noreply, socket |> put_flash(:info, "Feed removed.") |> load()}
  end

  # --- Async ---------------------------------------------------------------

  @impl true
  def handle_info({:drafted, id, result}, socket) do
    socket = update(socket, :drafting, &MapSet.delete(&1, id))

    case result do
      {:ok, _draft} ->
        {:noreply, load(socket)}

      {:error, :quota_exceeded, details} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You've used all #{details.limit} assisted replies for today."
         )}

      {:error, reason} ->
        require Logger
        Logger.warning("Reply drafting failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Couldn't write that reply. Try again in a moment.")}
    end
  end

  # --- Render --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header
      title="Engage"
      description="Who's talking to you, and which conversations are worth joining. Ordered by what's worth answering, not by what arrived last."
    />

    <p :if={!@api_configured} class="mb-8 max-w-[60ch] text-muted-foreground">
      Set <code class="nb-mono text-[12px] text-foreground">TWITTERAPI_IO_KEY</code>
      to pull mentions and feeds. Nothing here fills in without it.
    </p>

    <div class="mb-6 flex gap-6 border-b border-border">
      <.link patch={~p"/engage"} class="tab" aria-selected={is_nil(@kind)}>
        All <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, "all", 0)}</span>
      </.link>
      <.link patch={~p"/engage?kind=mention"} class="tab" aria-selected={@kind == "mention"}>
        Mentions
        <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, "mention", 0)}</span>
      </.link>
      <.link patch={~p"/engage?kind=feed"} class="tab" aria-selected={@kind == "feed"}>
        Feeds <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, "feed", 0)}</span>
      </.link>
    </div>

    <.feed_manager :if={@kind == "feed"} feeds={@feeds} />

    <div :if={@engagements == []} class="py-16 text-center">
      <p class="text-muted-foreground">
        <span :if={@kind == "feed" and @feeds == []}>
          No feeds yet. Add one above and SuperX will start surfacing conversations.
        </span>
        <span :if={@kind != "feed" or @feeds != []}>
          Nothing waiting. SuperX checks every twenty minutes.
        </span>
      </p>
    </div>

    <div class="flex flex-col gap-3">
      <div :for={engagement <- @engagements}>
        <.post
          author={
            %{
              name: engagement.author_name,
              handle: engagement.author_handle,
              avatar_url: engagement.author_avatar_url
            }
          }
          segments={[%{"text" => engagement.text}]}
          clamp={8}
        >
          <:meta>
            <span class={["nb-mono", priority_class(engagement.priority)]}>
              {engagement.priority || 0}
            </span>
            <span class="ml-2">{ago(engagement.posted_at)}</span>
            <span :if={engagement.priority_reason} class="ml-2">
              · {engagement.priority_reason}
            </span>
          </:meta>

          <:footer>
            <.metrics likes={engagement.likes} reposts={engagement.reposts} />
          </:footer>

          <:actions>
            <button
              :if={@ai_configured and engagement.reply_drafts == []}
              phx-click="draft"
              phx-value-id={engagement.id}
              disabled={MapSet.member?(@drafting, engagement.id)}
              class="act-key"
            >
              {if MapSet.member?(@drafting, engagement.id), do: "Writing…", else: "Draft a reply"}
            </button>
            <a href={Engagement.url(engagement)} target="_blank" rel="noopener" class="act">
              Open on 𝕏
            </a>
            <button phx-click="ignore" phx-value-id={engagement.id} class="act-danger">
              Ignore
            </button>
          </:actions>
        </.post>

        <%!-- The draft sits under the thing it answers, indented, so the
              pairing is structural rather than something you infer. --%>
        <div :for={draft <- engagement.reply_drafts} class="ml-6 mt-2 border-l border-border pl-4">
          <p class="nb-eyebrow mb-1.5">Your reply</p>
          <p class="post-body max-w-[60ch]">{draft.text}</p>

          <div class="mt-2.5 flex items-center gap-5 text-xs">
            <button phx-click="send" phx-value-draft_id={draft.id} class="act-key">
              Send reply
            </button>
            <button phx-click="dismiss_draft" phx-value-draft_id={draft.id} class="act-danger">
              Discard
            </button>
            <span class="nb-mono ml-auto text-[11px] text-faint">
              {String.length(draft.text)} / 280
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :feeds, :list, required: true

  defp feed_manager(assigns) do
    ~H"""
    <section class="mb-8 border-b border-border pb-6">
      <p class="nb-eyebrow mb-3">Your feeds</p>

      <ul :if={@feeds != []} class="mb-4 flex flex-col">
        <li
          :for={feed <- @feeds}
          class="flex items-baseline gap-4 border-b border-border py-2 first:border-t"
        >
          <span class={["flex-1", !feed.enabled && "text-faint line-through"]}>
            {feed.name}
            <span class="nb-mono ml-2 text-[11px] text-faint">{feed.query}</span>
          </span>
          <button phx-click="toggle_feed" phx-value-id={feed.id} class="act text-xs">
            {if feed.enabled, do: "Pause", else: "Resume"}
          </button>
          <button phx-click="delete_feed" phx-value-id={feed.id} class="act-danger text-xs">
            Remove
          </button>
        </li>
      </ul>

      <div :if={@feeds == []} class="mb-4 flex flex-wrap gap-4 text-xs">
        <span class="text-faint">Try:</span>
        <button
          :for={s <- Feed.suggestions()}
          phx-click="add_suggested"
          phx-value-query={s.query}
          phx-value-name={s.name}
          class="act"
        >
          {s.name}
        </button>
      </div>

      <form phx-submit="add_feed" class="flex items-end gap-4">
        <div class="flex-1">
          <label class="label" for="feed_query">Add a feed</label>
          <input
            type="text"
            id="feed_query"
            name="query"
            class="input"
            placeholder='"build in public" OR indie hacker'
            required
          />
        </div>
        <button type="submit" class="act-key pb-2 text-xs">Add</button>
      </form>
    </section>
    """
  end

  # Priority is the reason the inbox is ordered the way it is, so it earns
  # the accent when it's high rather than being another grey number.
  defp priority_class(p) when is_integer(p) and p >= 70, do: "text-primary"
  defp priority_class(p) when is_integer(p) and p >= 40, do: "text-muted-foreground"
  defp priority_class(_), do: "text-faint"
end
