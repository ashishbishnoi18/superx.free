defmodule SuperXWeb.InspirationLive do
  @moduledoc """
  Search the corpus of high-performing posts — the same library the
  writer draws structural templates from.
  """

  use SuperXWeb, :live_view

  alias SuperX.Content.{Corpus, Exclusions, VoiceProfile, Writer}

  @ranges [
    {"day", "Past 24 hours", 1},
    {"week", "Past week", 7},
    {"month", "Past month", 30},
    {"all", "All time", nil}
  ]

  @sorts ~w(engagement outlier)

  @impl true
  def mount(_params, _session, socket) do
    voice = SuperX.Content.get_voice_profile(socket.assigns.current_x_account)

    {:ok,
     socket
     |> assign(page_title: "Inspiration")
     |> assign(:query, "")
     |> assign(:range, "week")
     |> assign(:min_likes, 100)
     |> assign(:sort, "engagement")
     |> assign(:show_outliers, false)
     |> assign(:searching, false)
     |> assign(:ranges, @ranges)
     |> assign(:exclude, [])
     |> assign(:exclusions, Exclusions.categories())
     |> assign(:suggestions, suggestions(voice))
     |> assign(:corpus_size, Corpus.count())
     |> search()}
  end

  # Falls back to the same categories the library is seeded with, so the
  # chips offer something the corpus can actually answer.
  defp suggestions(nil), do: default_suggestions()

  defp suggestions(%VoiceProfile{} = voice) do
    case VoiceProfile.topic_list(voice) do
      [] -> default_suggestions()
      topics -> Enum.take(topics, 6)
    end
  end

  defp default_suggestions, do: Enum.take(SuperX.Workers.CorpusRefresh.seed_topics(), 6)

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
        sort: socket.assigns.sort,
        exclude: socket.assigns.exclude,
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

  def handle_event("set_sort", %{"sort" => sort}, socket) when sort in @sorts do
    {:noreply, socket |> assign(:sort, sort) |> search()}
  end

  def handle_event("toggle_outliers", _params, socket) do
    {:noreply, assign(socket, :show_outliers, not socket.assigns.show_outliers)}
  end

  def handle_event("toggle_exclude", %{"key" => key}, socket) do
    exclude =
      if key in socket.assigns.exclude do
        List.delete(socket.assigns.exclude, key)
      else
        [key | socket.assigns.exclude]
      end

    {:noreply, socket |> assign(:exclude, exclude) |> search()}
  end

  def handle_event("suggest", %{"topic" => topic}, socket) do
    {:noreply, socket |> assign(:query, topic) |> search()}
  end

  # Browsing the corpus and wanting to use *this* post is the obvious next
  # move, so it's one click rather than a trip back to Ready to Post and a
  # hope that the same post gets picked.
  def handle_event("draft_from", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.results, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      source ->
        user = socket.assigns.current_user
        account = socket.assigns.current_x_account
        parent = self()

        Task.Supervisor.start_child(SuperX.TaskSupervisor, fn ->
          send(parent, {:drafted, Writer.generate(user, account, source: source)})
        end)

        {:noreply, put_flash(socket, :info, "Writing a draft from that post…")}
    end
  end

  @impl true
  def handle_info({:drafted, {:ok, _generation}}, socket) do
    send(self(), :refresh_quota)

    {:noreply,
     socket
     |> put_flash(:info, "Draft ready.")
     |> push_navigate(to: ~p"/ready-to-post")}
  end

  def handle_info({:drafted, {:error, :quota_exceeded, _details}}, socket) do
    {:noreply, put_flash(socket, :error, "You're out of AI credits for this window.")}
  end

  def handle_info({:drafted, {:error, reason}}, socket) do
    require Logger
    Logger.warning("Draft-from-corpus failed: #{inspect(reason)}")

    {:noreply, put_flash(socket, :error, "Couldn't write that draft. Try again in a moment.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header
      title="Inspiration"
      description={"#{format_count(@corpus_size)} posts that outperformed their author's baseline. Search for structure worth borrowing, not subjects worth copying."}
    />

    <form id="inspiration-search" phx-change="search" phx-submit="search">
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

      <span class="text-border">·</span>

      <span class="text-faint">Hide</span>
      <button
        :for={category <- @exclusions}
        phx-click="toggle_exclude"
        phx-value-key={category.key}
        class={if category.key in @exclude, do: "act-key", else: "act"}
      >
        {category.label}
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

    <div class="mb-6 flex flex-wrap items-center gap-5 border-y border-border py-3 text-xs">
      <span class="text-faint">Sort</span>
      <button
        :for={{value, label} <- [{"engagement", "Engagement"}, {"outlier", "Outlier"}]}
        id={"sort-#{value}"}
        phx-click="set_sort"
        phx-value-sort={value}
        class={if @sort == value, do: "act-key", else: "act"}
        aria-pressed={@sort == value}
      >
        {label}
      </button>

      <span class="text-border">·</span>

      <label class="flex cursor-pointer items-center gap-2 text-muted-foreground">
        <input
          id="outlier-toggle"
          type="checkbox"
          checked={@show_outliers}
          phx-click="toggle_outliers"
        />
        <span>Show outlier scores</span>
      </label>
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

    <%!-- Masonry rather than a row grid: posts vary a lot in length, and
          equal-height cards would either clip the long ones or leave the
          short ones swimming in dead space. --%>
    <div id="inspiration-results" class="columns-1 gap-4 lg:columns-2 [&>*]:mb-4">
      <.post
        :for={post <- @results}
        id={"inspiration-post-#{post.id}"}
        author={corpus_author(post)}
        segments={segments(post)}
        class="break-inside-avoid"
      >
        <%!-- Likes and reposts only. Replies measure argument, not reach,
              and at masonry widths a third figure pushes the actions onto
              their own line for some cards and not others. --%>
        <:footer>
          <.metrics likes={post.likes} reposts={post.reposts} />
        </:footer>

        <:meta :if={@show_outliers and post.outlier_score >= 2.0}>
          <span
            id={"outlier-#{post.id}"}
            class="nb-mono text-[10px] text-muted-foreground"
            title={"#{format_outlier(post.outlier_score)} times typical engagement for this account size"}
          >
            <span class="text-foreground">{format_outlier(post.outlier_score)}×</span> typical
          </span>
        </:meta>

        <:actions>
          <button phx-click="draft_from" phx-value-id={post.id} class="act-key">
            Write one like this
          </button>
          <a href={corpus_url(post)} target="_blank" rel="noopener" class="act">Open</a>
        </:actions>
      </.post>
    </div>
    """
  end

  defp format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_count(n) when n >= 10_000, do: "#{round(n / 1_000)}K"
  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n), do: to_string(n)

  defp format_outlier(score), do: :erlang.float_to_binary(score, decimals: 1)
end
