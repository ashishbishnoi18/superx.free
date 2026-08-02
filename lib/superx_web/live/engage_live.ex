defmodule SuperXWeb.EngageLive do
  @moduledoc """
  The engagement inbox: mentions, replies, and topic feeds, ordered by what
  is actually worth answering.
  """

  use SuperXWeb, :live_view

  alias SuperX.Content
  alias SuperX.Content.Exclusions
  alias SuperX.Content.Post
  alias SuperX.Engage
  alias SuperX.Engage.{Engagement, Feed, Replier, ReplyDraft}
  alias SuperX.Workers.MentionSync

  @kinds ~w(mention feed replied)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Engage")
     |> assign(:kind, nil)
     |> assign(:min_likes, nil)
     |> assign(:min_followers, nil)
     |> assign(:verified_only, false)
     |> assign(:mention_type, nil)
     |> assign(:exclude, [])
     |> assign(:exclusions, Exclusions.categories())
     |> assign(:reply_sort, "recent")
     |> assign(:drafting, MapSet.new())
     |> assign(:refreshing_mentions, false)
     |> assign(:ai_configured, SuperX.AI.configured?())
     |> assign(:api_configured, SuperX.TwitterAPI.configured?())
     |> assign(:feed_form, feed_form())
     |> assign(:fetching_feed, nil)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    kind = if params["kind"] in @kinds, do: params["kind"]

    {:noreply,
     socket
     |> assign(:kind, kind)
     |> assign(:min_likes, int_param(params["min_likes"]))
     |> assign(:min_followers, int_param(params["min_followers"]))
     |> assign(:verified_only, params["verified"] == "1")
     |> assign(:mention_type, if(params["mtype"] in ~w(replies mentions), do: params["mtype"]))
     |> assign(:exclude, exclude_param(params["exclude"]))
     |> assign(
       :reply_sort,
       if(params["sort"] in ~w(likes views), do: params["sort"], else: "recent")
     )
     |> load()}
  end

  defp load(socket) do
    account = socket.assigns.current_x_account
    feeds = Engage.list_feeds(account)
    queries = feeds |> Enum.map(& &1.query) |> MapSet.new()

    starter_feeds =
      Enum.map(Feed.suggestions(), &Map.put(&1, :added, MapSet.member?(queries, &1.query)))

    engagements =
      account
      |> Engage.list_engagements(engagement_options(socket.assigns))
      |> sort_replied(socket.assigns)

    socket
    |> assign(:engagements, engagements)
    |> assign(:counts, Engage.counts(account))
    |> assign(:feeds, feeds)
    |> assign(:starter_feeds, starter_feeds)
  end

  # The mention filters only make sense on the tabs that list mentions;
  # the Feeds and My replies tabs have controls of their own.
  defp engagement_options(%{kind: "replied"} = assigns),
    do: [status: "replied", exclude: assigns.exclude]

  defp engagement_options(%{kind: kind} = assigns) when kind in [nil, "mention"] do
    [
      kind: kind,
      exclude: assigns.exclude,
      min_likes: assigns.min_likes,
      min_author_followers: assigns.min_followers,
      verified_only: assigns.verified_only,
      mention_type: assigns.mention_type
    ]
  end

  defp engagement_options(%{kind: kind} = assigns),
    do: [kind: kind, exclude: assigns.exclude]

  # Metric sorting happens here rather than in SQL: the numbers live in a
  # jsonb map on the preloaded replied post, and the list is capped at
  # fifty rows, so an `ORDER BY (metrics->>'likes')::int` over a join would
  # buy nothing measurable.
  defp sort_replied(engagements, %{kind: "replied", reply_sort: "likes"}),
    do: Enum.sort_by(engagements, &reply_metric(&1, "likes"), :desc)

  defp sort_replied(engagements, %{kind: "replied", reply_sort: "views"}),
    do: Enum.sort_by(engagements, &reply_metric(&1, "views"), :desc)

  defp sort_replied(engagements, _assigns), do: engagements

  defp reply_metric(%{replied_post: %{metrics: metrics}}, key) when is_map(metrics),
    do: metrics[key] || 0

  defp reply_metric(_engagement, _key), do: 0

  # Every control on this page rides in the query string, so a narrowed or
  # resorted inbox survives a refresh and can be shared or carried across
  # tabs. Defaults stay out of the URL so plain links remain clean.
  defp engage_path(assigns, overrides) do
    params =
      %{
        "kind" => assigns.kind,
        "min_likes" => assigns.min_likes,
        "min_followers" => assigns.min_followers,
        "verified" => if(assigns.verified_only, do: "1"),
        "mtype" => assigns.mention_type,
        "exclude" => Enum.join(assigns.exclude, ","),
        "sort" => if(assigns.reply_sort == "recent", do: nil, else: assigns.reply_sort)
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn
        {"sort", value} -> value in [nil, "", "recent"]
        {_key, value} -> value in [nil, ""]
      end)
      |> Map.new()

    if params == %{}, do: ~p"/engage", else: ~p"/engage?#{params}"
  end

  defp int_param(value) do
    case Integer.parse(to_string(value || "")) do
      {minimum, ""} when minimum > 0 -> minimum
      _ -> nil
    end
  end

  defp exclude_param(value) do
    valid = Enum.map(Exclusions.categories(), & &1.key)

    (value || "")
    |> String.split(",", trim: true)
    |> Enum.filter(&(&1 in valid))
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

    with %ReplyDraft{status: "shelf"} = draft <- Engage.get_draft(user, draft_id),
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

  def handle_event("retry_reply", %{"post_id" => post_id}, socket) do
    with %{} = post <-
           Content.get_post(
             socket.assigns.current_user,
             socket.assigns.current_x_account,
             post_id
           ),
         {:ok, _retried} <- Content.retry_post(post) do
      {:noreply, socket |> put_flash(:info, "Reply queued to try again.") |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, "We couldn't retry that reply.")}
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

  # --- Filters ---------------------------------------------------------------

  def handle_event("set_mention_filters", params, socket) do
    overrides = %{
      "min_likes" => int_param(params["min_likes"]),
      "min_followers" => int_param(params["min_followers"]),
      "verified" => if(params["verified"] == "1", do: "1"),
      "mtype" => if(params["mtype"] in ~w(replies mentions), do: params["mtype"])
    }

    {:noreply, push_patch(socket, to: engage_path(socket.assigns, overrides))}
  end

  def handle_event("toggle_exclude", %{"key" => key}, socket) do
    exclude =
      if key in socket.assigns.exclude do
        List.delete(socket.assigns.exclude, key)
      else
        [key | socket.assigns.exclude]
      end

    {:noreply,
     push_patch(socket, to: engage_path(socket.assigns, %{"exclude" => Enum.join(exclude, ",")}))}
  end

  # --- Mention refresh ----------------------------------------------------

  def handle_event("refresh_mentions", _params, %{assigns: %{refreshing_mentions: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("refresh_mentions", _params, socket) do
    account = socket.assigns.current_x_account
    parent = self()

    Task.Supervisor.start_child(SuperX.TaskSupervisor, fn ->
      send(parent, {:mentions_refreshed, MentionSync.sync_mentions(account)})
    end)

    {:noreply,
     socket
     |> assign(:refreshing_mentions, true)
     |> put_flash(:info, "Checking for mentions…")}
  end

  # --- Feeds ---------------------------------------------------------------

  def handle_event("add_feed", %{"feed" => %{"query" => query}}, socket) do
    attrs = %{query: String.trim(query), min_likes: 50}

    case Engage.create_feed(socket.assigns.current_x_account, attrs) do
      {:ok, feed} ->
        {:noreply,
         socket
         |> assign(:feed_form, feed_form())
         |> fetch_now(feed)
         |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That feed already exists.")}
    end
  end

  def handle_event("add_suggested", %{"query" => query, "name" => name}, socket) do
    case Engage.create_feed(socket.assigns.current_x_account, %{
           query: query,
           name: name,
           min_likes: 30
         }) do
      {:ok, feed} -> {:noreply, socket |> fetch_now(feed) |> load()}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  def handle_event("fetch_feed", %{"id" => id}, socket) do
    case Engage.get_feed(socket.assigns.current_x_account, id) do
      nil -> {:noreply, socket}
      feed -> {:noreply, socket |> fetch_now(feed) |> load()}
    end
  end

  def handle_event("toggle_feed", %{"id" => id}, socket) do
    Engage.toggle_feed(socket.assigns.current_x_account, id)
    {:noreply, load(socket)}
  end

  def handle_event("set_feed_ranking", %{"id" => id, "ranking" => ranking}, socket) do
    case Engage.set_feed_ranking(socket.assigns.current_x_account, id, ranking) do
      {:ok, _feed} -> {:noreply, load(socket)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "We couldn't change that feed.")}
    end
  end

  def handle_event("delete_feed", %{"id" => id}, socket) do
    Engage.delete_feed(socket.assigns.current_x_account, id)
    {:noreply, socket |> put_flash(:info, "Feed removed.") |> load()}
  end

  # --- Async ---------------------------------------------------------------

  # A feed nobody has fetched is indistinguishable from a broken one, so
  # adding a subject fetches it there and then. Off the render because a
  # search is a couple of seconds of somebody else's network, and the page
  # should not sit blank for it.
  defp fetch_now(socket, feed) do
    account = socket.assigns.current_x_account
    parent = self()

    Task.Supervisor.start_child(SuperX.TaskSupervisor, fn ->
      send(parent, {:feed_fetched, MentionSync.sync_feed(%{feed | x_account: account})})
    end)

    socket
    |> assign(:fetching_feed, feed.id)
    |> put_flash(:info, "Looking for posts about #{feed.name || feed.query}…")
  end

  @impl true
  def handle_info({:feed_fetched, result}, socket) do
    socket = assign(socket, :fetching_feed, nil)

    {:noreply,
     case result do
       {:ok, 0} ->
         socket
         |> put_flash(:info, "Nothing matched yet. SuperX checks again every twenty minutes.")
         |> load()

       {:ok, n} ->
         socket |> put_flash(:info, "Found #{n} post(s) worth a look.") |> load()

       {:error, :out_of_credits} ->
         put_flash(socket, :error, "The read API is out of credits.")

       {:error, _reason} ->
         put_flash(socket, :error, "Couldn't reach the search API. It'll retry on the next poll.")
     end}
  end

  def handle_info({:mentions_refreshed, result}, socket) do
    socket = assign(socket, :refreshing_mentions, false)

    {:noreply,
     case result do
       {:ok, 0} ->
         socket |> put_flash(:info, "No mentions found just now.") |> load()

       {:ok, n} ->
         socket |> put_flash(:info, "Found #{n} mention(s).") |> load()

       {:error, :out_of_credits} ->
         put_flash(socket, :error, "The read API is out of credits.")

       {:error, _reason} ->
         put_flash(socket, :error, "Couldn't refresh mentions. Try again in a moment.")
     end}
  end

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
      description={
        if @kind == "feed",
          do: "Conversations worth joining, newest first.",
          else:
            "Who's talking to you, and which conversations are worth joining. Mentions lead with what's worth answering; feeds read newest first."
      }
    >
      <:action :if={@api_configured and @kind != "feed" and @kind != "replied"}>
        <button
          id="refresh-mentions"
          phx-click="refresh_mentions"
          disabled={@refreshing_mentions}
          class="act-key whitespace-nowrap"
        >
          {if @refreshing_mentions, do: "Refreshing…", else: "Refresh mentions"}
        </button>
      </:action>
    </Layouts.page_header>

    <p :if={!@api_configured} class="mb-8 max-w-[60ch] text-muted-foreground">
      Set <code class="nb-mono text-[12px] text-foreground">TWITTERAPI_IO_KEY</code>
      to pull mentions and feeds. Nothing here fills in without it.
    </p>

    <div class="mb-9 flex gap-6 border-b border-border">
      <.link
        patch={engage_path(assigns, %{"kind" => nil})}
        class="tab"
        aria-selected={to_string(is_nil(@kind))}
      >
        All <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, "all", 0)}</span>
      </.link>
      <.link
        patch={engage_path(assigns, %{"kind" => "mention"})}
        class="tab"
        aria-selected={to_string(@kind == "mention")}
      >
        Mentions
        <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, "mention", 0)}</span>
      </.link>
      <.link
        patch={engage_path(assigns, %{"kind" => "feed"})}
        class="tab"
        aria-selected={to_string(@kind == "feed")}
      >
        Feeds <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, "feed", 0)}</span>
      </.link>
      <.link
        patch={engage_path(assigns, %{"kind" => "replied"})}
        class="tab"
        aria-selected={to_string(@kind == "replied")}
      >
        My replies
        <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, "replied", 0)}</span>
      </.link>
    </div>

    <form
      :if={is_nil(@kind) or @kind == "mention"}
      id="engage-mention-filters"
      phx-change="set_mention_filters"
      class="-mt-5 mb-9 flex flex-wrap items-center gap-x-5 gap-y-2 text-xs"
    >
      <span class="text-faint">Filter</span>

      <label for="engage-filter-min-likes" class="flex items-center gap-1.5 text-muted-foreground">
        Min likes
        <input
          type="number"
          name="min_likes"
          id="engage-filter-min-likes"
          value={@min_likes}
          min="0"
          placeholder="Any"
          class="input w-20 px-2 py-1 text-xs"
          phx-debounce="300"
        />
      </label>

      <label
        for="engage-filter-min-followers"
        class="flex items-center gap-1.5 text-muted-foreground"
      >
        Min followers
        <input
          type="number"
          name="min_followers"
          id="engage-filter-min-followers"
          value={@min_followers}
          min="0"
          placeholder="Any"
          class="input w-24 px-2 py-1 text-xs"
          phx-debounce="300"
        />
      </label>

      <label class="flex cursor-pointer items-center gap-2 text-muted-foreground">
        <input
          type="checkbox"
          name="verified"
          id="engage-filter-verified"
          value="1"
          checked={@verified_only}
        /> Verified only
      </label>

      <select
        id="engage-filter-type"
        name="mtype"
        class="select w-auto py-1 text-xs"
        aria-label="Mention type"
      >
        <option value="" selected={is_nil(@mention_type)}>All types</option>
        <option value="replies" selected={@mention_type == "replies"}>Replies to me</option>
        <option value="mentions" selected={@mention_type == "mentions"}>Mentions</option>
      </select>
    </form>

    <div
      :if={@kind == "feed"}
      id="engage-exclusions"
      class="-mt-5 mb-9 flex flex-wrap items-center gap-5 text-xs"
    >
      <span class="text-faint">Hide</span>
      <button
        :for={category <- @exclusions}
        id={"engage-exclude-#{category.key}"}
        phx-click="toggle_exclude"
        phx-value-key={category.key}
        class={if category.key in @exclude, do: "act-key", else: "act"}
        aria-pressed={to_string(category.key in @exclude)}
      >
        {category.label}
      </button>
    </div>

    <div
      :if={@kind == "replied"}
      id="engage-reply-sort"
      class="-mt-5 mb-9 flex items-center gap-5 text-xs"
    >
      <span class="text-faint">Sort</span>
      <.link
        :for={
          {value, label} <- [{"recent", "Recent"}, {"likes", "Most likes"}, {"views", "Most views"}]
        }
        id={"engage-sort-#{value}"}
        patch={engage_path(assigns, %{"sort" => value})}
        class={if @reply_sort == value, do: "act-key", else: "act"}
        aria-pressed={to_string(@reply_sort == value)}
      >
        {label}
      </.link>
    </div>

    <.feed_manager
      :if={@kind == "feed"}
      feeds={@feeds}
      starter_feeds={@starter_feeds}
      feed_form={@feed_form}
      fetching_feed={@fetching_feed}
    />

    <div :if={@engagements == []} class="py-16 text-center">
      <.icon name="hero-chat-bubble-left-right" class="size-6 text-faint" />
      <p class="nb-eyebrow mb-2 mt-3">Engage</p>
      <p class="text-muted-foreground">
        <span :if={@kind == "feed" and @feeds == []}>
          No feeds yet. Add one above and SuperX will start surfacing conversations.
        </span>
        <span :if={@kind == "replied"}>
          No replies yet. Replies you queue and send will stay visible here.
        </span>
        <span
          :if={
            not @api_configured and @kind != "replied" and
              (@kind != "feed" or @feeds != [])
          }
          id="engage-empty-unconfigured"
        >
          Mention and feed syncing is not configured, so this inbox cannot fill yet.
        </span>
        <span :if={@refreshing_mentions and @kind != "feed" and @kind != "replied"}>
          Refreshing mentions…
        </span>
        <span
          :if={
            @api_configured and @kind != "replied" and not @refreshing_mentions and
              (@kind != "feed" or @feeds != [])
          }
          id="engage-empty-current"
        >
          Nothing waiting. SuperX checks every twenty minutes.
        </span>
      </p>
    </div>

    <div class="flex flex-col gap-3">
      <div :for={engagement <- @engagements} id={"engagement-#{engagement.x_post_id}"}>
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
          timestamp={ago(engagement.posted_at)}
          class="post-interactive"
        >
          <:meta>
            <span class="score" data-tier={score_tier(engagement.priority)}>
              {engagement.priority || 0}
            </span>
            <span :if={engagement.priority_reason} class="ml-2">
              · {engagement.priority_reason}
            </span>
          </:meta>

          <:footer>
            <.metrics likes={engagement.likes} reposts={engagement.reposts} />
          </:footer>

          <:actions>
            <button
              :if={@kind != "replied" and @ai_configured and engagement.reply_drafts == []}
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
            <button
              :if={@kind != "replied"}
              phx-click="ignore"
              phx-value-id={engagement.id}
              class="act-danger"
            >
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
            <button
              id={"send-reply-#{draft.id}"}
              phx-click="send"
              phx-value-draft_id={draft.id}
              phx-disable-with="Sending…"
              class="act-key"
            >
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

        <div
          :if={@kind == "replied" and engagement.replied_post}
          id={"reply-post-#{engagement.replied_post.id}"}
          class="ml-6 mt-2 border-l border-border pl-4"
        >
          <p class="nb-eyebrow mb-1.5">{reply_state_label(engagement.replied_post)}</p>
          <p class="post-body max-w-[60ch]">{Post.preview_text(engagement.replied_post)}</p>

          <p
            :if={engagement.replied_post.status == "failed"}
            id={"reply-post-#{engagement.replied_post.id}-error"}
            class="mt-1.5 text-[12px] text-destructive"
          >
            {engagement.replied_post.error}
          </p>

          <%!-- How the reply itself is landing. Only shown once the metrics
                cron has pulled numbers — a reply without them renders the
                same as before rather than a row of zeros. --%>
          <div
            :if={engagement.replied_post.metrics_updated_at}
            id={"reply-post-#{engagement.replied_post.id}-metrics"}
            class="mt-2.5 flex items-center gap-3"
          >
            <.metrics
              likes={engagement.replied_post.metrics["likes"]}
              reposts={engagement.replied_post.metrics["reposts"]}
              replies={engagement.replied_post.metrics["replies"]}
              impressions={engagement.replied_post.metrics["views"]}
            />
            <span
              id={"reply-post-#{engagement.replied_post.id}-metrics-checked"}
              class="nb-mono text-[11px] text-faint"
            >
              checked {ago(engagement.replied_post.metrics_updated_at)}
            </span>
          </div>

          <div class="mt-2.5 flex items-center gap-5 text-xs">
            <button
              :if={
                engagement.replied_post.status == "failed" and
                  engagement.replied_post.x_post_ids == []
              }
              id={"retry-reply-#{engagement.replied_post.id}"}
              phx-click="retry_reply"
              phx-value-post_id={engagement.replied_post.id}
              class="act-key"
            >
              Try again
            </button>
            <.link
              :if={
                engagement.replied_post.status == "failed" and
                  engagement.replied_post.x_post_ids == []
              }
              id={"edit-reply-#{engagement.replied_post.id}"}
              navigate={~p"/queue/#{engagement.replied_post.id}"}
              class="act"
            >
              Edit before retrying
            </.link>
            <a
              :if={engagement.replied_post.permalink}
              href={engagement.replied_post.permalink}
              target="_blank"
              rel="noopener"
              class="act"
            >
              View your reply on 𝕏
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :feeds, :list, required: true
  attr :starter_feeds, :list, required: true
  attr :feed_form, :map, required: true
  attr :fetching_feed, :string, default: nil, doc: "id of the feed being fetched right now"

  defp feed_manager(assigns) do
    ~H"""
    <section class="mb-9 border-b border-border pb-6">
      <p class="nb-eyebrow mb-3">Your feeds</p>

      <ul :if={@feeds != []} id="topic-feeds" class="mb-6 flex flex-col">
        <li
          :for={feed <- @feeds}
          id={"topic-feed-#{feed.id}"}
          class="border-b border-border py-3 first:border-t"
        >
          <div class="flex flex-wrap items-baseline gap-x-4 gap-y-2">
            <span class={["min-w-0 flex-1", !feed.enabled && "text-faint line-through"]}>
              {feed.name}
              <span class="nb-mono ml-2 text-[11px] text-faint">{feed.query}</span>
            </span>

            <div class="flex items-center gap-3 text-xs">
              <span class="nb-eyebrow">Pull</span>
              <button
                id={"feed-#{feed.id}-relevance"}
                phx-click="set_feed_ranking"
                phx-value-id={feed.id}
                phx-value-ranking="relevance"
                class={if(feed.ranking == "relevance", do: "act-key", else: "act")}
                aria-pressed={to_string(feed.ranking == "relevance")}
                title="Ask X for its top matches"
              >
                Top
              </button>
              <button
                id={"feed-#{feed.id}-newest"}
                phx-click="set_feed_ranking"
                phx-value-id={feed.id}
                phx-value-ranking="newest"
                class={if(feed.ranking == "newest", do: "act-key", else: "act")}
                aria-pressed={to_string(feed.ranking == "newest")}
                title="Ask X for the newest matches"
              >
                Latest
              </button>
            </div>

            <div class="flex items-center gap-4 text-xs">
              <button
                id={"feed-#{feed.id}-fetch"}
                phx-click="fetch_feed"
                phx-value-id={feed.id}
                class="act-key"
                disabled={@fetching_feed == feed.id}
              >
                {if @fetching_feed == feed.id, do: "Fetching…", else: "Fetch now"}
              </button>
              <button
                id={"feed-#{feed.id}-toggle"}
                phx-click="toggle_feed"
                phx-value-id={feed.id}
                class="act"
              >
                {if feed.enabled, do: "Pause", else: "Resume"}
              </button>
              <button
                id={"feed-#{feed.id}-remove"}
                phx-click="delete_feed"
                phx-value-id={feed.id}
                class="act-danger"
              >
                Remove
              </button>
            </div>
          </div>
        </li>
      </ul>

      <div id="feed-starters" class="mb-6">
        <p class="nb-eyebrow mb-1.5">Ready-made feeds</p>
        <p class="mb-3 max-w-[60ch] text-xs text-muted-foreground">
          Add a subject in one click. You can tune how each feed is ranked afterwards.
        </p>

        <div class="grid border-t border-border sm:grid-cols-2 sm:gap-x-6">
          <button
            :for={feed <- @starter_feeds}
            id={"starter-#{starter_id(feed.name)}"}
            phx-click="add_suggested"
            phx-value-query={feed.query}
            phx-value-name={feed.name}
            disabled={feed.added}
            class={[
              "flex items-center justify-between border-b border-border py-2 text-left text-xs",
              if(feed.added, do: "text-faint", else: "act-key")
            ]}
          >
            <span>{feed.name}</span>
            <span :if={feed.added} class="nb-mono text-[10px]">Added</span>
          </button>
        </div>
      </div>

      <.form for={@feed_form} id="feed-search-form" phx-submit="add_feed" class="flex items-end gap-4">
        <div class="min-w-0 flex-1">
          <.input
            field={@feed_form[:query]}
            type="search"
            label="Search your own"
            placeholder='"developer experience" OR devex'
            required
          />
        </div>
        <button type="submit" class="act-key pb-2 text-xs" phx-disable-with="Adding…">Add</button>
      </.form>
    </section>
    """
  end

  defp feed_form, do: to_form(%{"query" => ""}, as: :feed)

  defp starter_id(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # Priority is the reason the inbox is ordered the way it is, so it earns
  # the accent when it's high rather than being another grey number.
  # Three steps, matching the `.score` ramp used for match scores on
  # Contacts, so a number in this product always means the same thing.
  defp score_tier(p) when is_integer(p) and p >= 70, do: "strong"
  defp score_tier(p) when is_integer(p) and p >= 40, do: "mid"
  defp score_tier(_), do: "weak"

  defp reply_state_label(%Post{status: "posted"}), do: "Your reply"
  defp reply_state_label(%Post{status: "failed"}), do: "Reply failed"
  defp reply_state_label(%Post{}), do: "Reply queued"
end
