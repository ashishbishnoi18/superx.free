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
    <Layouts.page_header
      title="Inspiration"
      description={"#{format_count(@corpus_size)} posts that outperformed their author's baseline. Search for structure worth borrowing, not subjects worth copying."}
    />

    <form phx-change="search" phx-submit="search">
      <input
        type="search"
        name="query"
        value={@query}
        placeholder="Search the library…"
        class="input text-[15px]"
        phx-debounce="300"
        autocomplete="off"
        aria-label="Search the library"
      />
    </form>

    <div class="flex flex-wrap gap-5 py-3 text-xs">
      <button
        :for={{key, label, _} <- @ranges}
        phx-click="set_range"
        phx-value-range={key}
        class={if @range == key, do: "act-key", else: "act"}
      >
        {label}
      </button>

      <span class="text-border">·</span>

      <button
        :for={n <- [100, 500, 5000, 20_000]}
        phx-click="set_min_likes"
        phx-value-min_likes={n}
        class={if @min_likes == n, do: "act-key", else: "act"}
      >
        {format_count(n)}+ likes
      </button>
    </div>

    <div class="flex flex-wrap gap-4 pb-6 text-xs">
      <button
        :for={topic <- @suggestions}
        phx-click="suggest"
        phx-value-topic={topic}
        class={if @query == topic, do: "act-key", else: "act"}
      >
        {topic}
      </button>
    </div>

    <div :if={@corpus_size == 0} class="py-16 text-center">
      <p class="text-muted-foreground">
        The library is empty. Point the ingestion worker at the topics you care about —
        see <code class="nb-mono text-[12px] text-foreground">scraper/README.md</code>.
      </p>
    </div>

    <div :if={@corpus_size > 0 and @results == []} class="py-16 text-center">
      <p class="text-muted-foreground">
        Nothing matched. Try a broader term or a lower threshold.
      </p>
    </div>

    <div class="flex flex-col">
      <article
        :for={post <- @results}
        class="grid grid-cols-1 gap-8 border-t border-border py-5 last:border-b sm:grid-cols-[minmax(0,1fr)_8rem]"
      >
        <div class="min-w-0">
          <p class="mb-1.5 text-[12px]">
            <a
              href={"https://x.com/#{post.author_handle}"}
              target="_blank"
              rel="noopener"
              class="hover-ember font-medium"
            >
              {post.author_name || post.author_handle}
            </a>
            <span class="text-faint">@{post.author_handle}</span>
          </p>
          <a
            href={"https://x.com/#{post.author_handle}/status/#{post.x_post_id}"}
            target="_blank"
            rel="noopener"
            class="hover-ember block max-w-[60ch] whitespace-pre-wrap leading-[1.6]"
          >{post.text}</a>
        </div>

        <div class="nb-mono flex flex-row gap-4 text-[11px] text-faint sm:flex-col sm:gap-0.5 sm:text-right">
          <span><b class="font-medium text-muted-foreground">{format_count(post.likes)}</b> likes</span>
          <span>{format_count(post.reposts)} reposts</span>
          <span>{relative(post.posted_at)}</span>
        </div>
      </article>
    </div>
    """
  end

  defp relative(datetime) do
    case DateTime.diff(DateTime.utc_now(), datetime, :second) do
      s when s < 3600 -> "just now"
      s when s < 86_400 -> "#{div(s, 3600)}h ago"
      s -> "#{div(s, 86_400)}d ago"
    end
  end

  defp format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_count(n) when n >= 10_000, do: "#{round(n / 1_000)}K"
  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n), do: to_string(n)
end
