defmodule SuperXWeb.InspirationLive do
  @moduledoc """
  Search the corpus of high-performing posts — the same library the
  writer draws structural templates from.
  """

  use SuperXWeb, :live_view

  alias SuperX.Content.{Corpus, VoiceProfile}

  @ranges [{"day", "Past 24 hours", 1}, {"week", "Past week", 7}, {"month", "Past month", 30},
           {"all", "All time", nil}]

  @impl true
  def mount(_params, _session, socket) do
    voice = SuperX.Content.get_voice_profile(socket.assigns.current_x_account)

    {:ok,
     socket
     |> assign(page_title: "Inspiration")
     |> assign(:query, "")
     |> assign(:range, "week")
     |> assign(:min_likes, 100)
     |> assign(:searching, false)
     |> assign(:ranges, @ranges)
     |> assign(:suggestions, suggestions(voice))
     |> assign(:corpus_size, Corpus.count())
     |> search()}
  end

  defp suggestions(nil), do: ["startups", "writing", "productivity", "design"]

  defp suggestions(%VoiceProfile{} = voice) do
    case VoiceProfile.topic_list(voice) do
      [] -> ["startups", "writing", "productivity", "design"]
      topics -> Enum.take(topics, 6)
    end
  end

  defp search(socket) do
    since =
      case Enum.find(@ranges, fn {key, _, _} -> key == socket.assigns.range end) do
        {_, _, nil} -> nil
        {_, _, days} -> DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)
        _ -> nil
      end

    results =
      Corpus.search(
        query: socket.assigns.query,
        since: since,
        min_likes: socket.assigns.min_likes,
        limit: 48
      )

    assign(socket, :results, results)
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(:query, query) |> search()}
  end

  def handle_event("set_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:range, range) |> search()}
  end

  def handle_event("set_min_likes", %{"min_likes" => value}, socket) do
    {:noreply, socket |> assign(:min_likes, String.to_integer(value)) |> search()}
  end

  def handle_event("suggest", %{"topic" => topic}, socket) do
    {:noreply, socket |> assign(:query, topic) |> search()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold tracking-tight">Inspiration</h1>
        <p class="mt-1 text-sm" style="color: var(--text-secondary)">
          {format_count(@corpus_size)} posts that outperformed. Search for structure worth borrowing.
        </p>
      </div>

      <form phx-change="search" phx-submit="search" class="space-y-3">
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2"
            style="color: var(--text-muted)"
          />
          <input
            type="search"
            name="query"
            value={@query}
            placeholder="Search by keyword…"
            class="input pl-9"
            phx-debounce="300"
            autocomplete="off"
          />
        </div>
      </form>

      <div class="flex flex-wrap gap-2">
        <button
          :for={topic <- @suggestions}
          phx-click="suggest"
          phx-value-topic={topic}
          class={["badge cursor-pointer", @query == topic && "badge-ember"]}
        >
          {topic}
        </button>
      </div>

      <div class="flex flex-wrap items-center gap-4 text-sm">
        <div class="flex items-center gap-1.5">
          <span style="color: var(--text-muted)">Posted</span>
          <select
            class="select w-auto py-1 text-sm"
            phx-change="set_range"
            name="range"
          >
            <option :for={{key, label, _} <- @ranges} value={key} selected={@range == key}>
              {label}
            </option>
          </select>
        </div>

        <div class="flex items-center gap-1.5">
          <span style="color: var(--text-muted)">Minimum likes</span>
          <select
            class="select w-auto py-1 text-sm"
            phx-change="set_min_likes"
            name="min_likes"
          >
            <option :for={n <- [0, 100, 500, 1000, 5000, 10_000]} value={n} selected={@min_likes == n}>
              {format_count(n)}
            </option>
          </select>
        </div>
      </div>

      <div :if={@corpus_size == 0} class="card p-10 text-center">
        <.icon name="hero-inbox" class="mx-auto size-8" style="color: var(--text-muted)" />
        <p class="mt-3 font-semibold">The library is empty</p>
        <p class="mx-auto mt-1 max-w-md text-sm" style="color: var(--text-secondary)">
          Run the ingestion worker to populate it. See
          <code class="font-mono text-xs">scraper/README.md</code>
          for how to point it at the topics you care about.
        </p>
      </div>

      <div :if={@corpus_size > 0 and @results == []} class="card p-10 text-center">
        <p class="text-sm" style="color: var(--text-secondary)">
          Nothing matched. Try a broader term or a lower like threshold.
        </p>
      </div>

      <div class="columns-1 gap-4 md:columns-2 lg:columns-3 [&>*]:mb-4">
        <article :for={post <- @results} class="card card-interactive break-inside-avoid p-4">
          <div class="flex items-center gap-2.5">
            <Layouts.avatar src={post.author_avatar_url} size="size-9" />
            <div class="min-w-0">
              <p class="truncate text-sm font-semibold">{post.author_name || post.author_handle}</p>
              <p class="truncate text-xs" style="color: var(--text-muted)">
                @{post.author_handle} · {format_count(post.author_followers)} followers
              </p>
            </div>
          </div>

          <p class="mt-3 whitespace-pre-wrap text-[0.9375rem] leading-relaxed">{post.text}</p>

          <div
            class="mt-3 flex items-center gap-4 text-xs tabular-nums"
            style="color: var(--text-muted)"
          >
            <span><.icon name="hero-heart" class="mr-0.5 inline size-3" />{format_count(post.likes)}</span>
            <span>
              <.icon name="hero-arrow-path-rounded-square" class="mr-0.5 inline size-3" />{format_count(
                post.reposts
              )}
            </span>
            <span>
              <.icon name="hero-chat-bubble-oval-left" class="mr-0.5 inline size-3" />{format_count(
                post.replies
              )}
            </span>
            <a
              href={"https://x.com/#{post.author_handle}/status/#{post.x_post_id}"}
              target="_blank"
              rel="noopener"
              class="ml-auto hover:underline"
            >
              Open
            </a>
          </div>
        </article>
      </div>
    </div>
    """
  end

  defp format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_count(n) when n >= 10_000, do: "#{round(n / 1_000)}K"
  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n), do: to_string(n)
end
