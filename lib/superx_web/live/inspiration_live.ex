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

  @range_keys Enum.map(@ranges, &elem(&1, 0))
  @sorts ~w(engagement outlier)
  @tabs ~w(posts media)
  @advanced_defaults %{
    "min_reposts" => "",
    "min_replies" => "",
    "min_bookmarks" => "",
    "min_views" => "",
    "min_length" => "",
    "date_from" => "",
    "date_to" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    voice = SuperX.Content.get_voice_profile(socket.assigns.current_x_account)

    {:ok,
     socket
     |> assign(page_title: "Inspiration")
     |> assign(:query, "")
     |> assign(:tab, "posts")
     |> assign(:range, "week")
     |> assign(:min_likes, 100)
     |> assign(:sort, "engagement")
     |> assign(:show_outliers, false)
     |> assign(:searching, false)
     |> assign(:ranges, @ranges)
     |> assign(:exclude, [])
     |> assign(:exclusions, Exclusions.categories())
     |> assign_advanced(@advanced_defaults)
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
    {since, until} =
      date_bounds(
        socket.assigns.range,
        socket.assigns.advanced_filters,
        socket.assigns.current_user.timezone
      )

    filters = socket.assigns.advanced_filters

    results =
      Corpus.search(
        query: socket.assigns.query,
        since: since,
        until: until,
        min_likes: socket.assigns.min_likes,
        min_reposts: minimum(filters["min_reposts"]),
        min_replies: minimum(filters["min_replies"]),
        min_bookmarks: minimum(filters["min_bookmarks"]),
        min_views: minimum(filters["min_views"]),
        min_length: minimum(filters["min_length"]),
        has_media: if(socket.assigns.tab == "media", do: true, else: nil),
        sort: socket.assigns.sort,
        exclude: socket.assigns.exclude,
        limit: 48
      )

    socket
    |> assign(:results, results)
    |> assign(:invalid_date_range, invalid_date_range?(filters))
    |> assign(:empty_filter_summary, empty_filter_summary(socket.assigns))
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(:query, query) |> search()}
  end

  def handle_event("set_tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply, socket |> assign(:tab, tab) |> search()}
  end

  def handle_event("set_range", %{"range" => range}, socket) when range in @range_keys do
    filters = Map.merge(socket.assigns.advanced_filters, %{"date_from" => "", "date_to" => ""})

    {:noreply, socket |> assign(:range, range) |> assign_advanced(filters) |> search()}
  end

  def handle_event("set_min_likes", %{"min_likes" => value}, socket) do
    case Integer.parse(value) do
      {minimum, ""} when minimum >= 0 ->
        {:noreply, socket |> assign(:min_likes, minimum) |> search()}

      _ ->
        {:noreply, socket}
    end
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

  def handle_event("filter_advanced", %{"filters" => params}, socket) do
    filters = normalize_advanced(params)

    range =
      cond do
        custom_dates?(filters) -> "custom"
        socket.assigns.range == "custom" -> "all"
        true -> socket.assigns.range
      end

    {:noreply, socket |> assign(:range, range) |> assign_advanced(filters) |> search()}
  end

  def handle_event("reset_advanced", _params, socket) do
    range = if socket.assigns.range == "custom", do: "all", else: socket.assigns.range

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign_advanced(@advanced_defaults)
     |> search()}
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

    <div id="inspiration-tabs" class="mb-5 flex gap-6 border-b border-border text-sm">
      <button
        :for={{value, label} <- [{"posts", "Posts"}, {"media", "Media"}]}
        id={"tab-#{value}"}
        phx-click="set_tab"
        phx-value-tab={value}
        class={[
          "border-b pb-2.5 transition-colors",
          if(@tab == value,
            do: "act-key border-primary text-primary",
            else: "act border-transparent"
          )
        ]}
        aria-pressed={to_string(@tab == value)}
      >
        {label}
      </button>
    </div>

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

    <div class="flex flex-wrap gap-4 pb-5 text-xs">
      <button
        :for={topic <- @suggestions}
        phx-click="suggest"
        phx-value-topic={topic}
        class={if @query == topic, do: "act-key", else: "act"}
      >
        {topic}
      </button>
    </div>

    <details
      id="advanced-filters"
      class="group border-t border-border py-3"
      open={advanced_filter_count(@advanced_filters) > 0}
    >
      <summary class="act flex cursor-pointer list-none items-center gap-2 text-xs [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right"
          class="size-3.5 transition-transform group-open:rotate-90"
        />
        <span>Advanced filters</span>
        <span
          :if={advanced_filter_count(@advanced_filters) > 0}
          class="nb-mono text-[10px] text-primary"
        >
          {advanced_filter_count(@advanced_filters)} active
        </span>
      </summary>

      <.form
        for={@advanced_form}
        id="advanced-filter-form"
        phx-change="filter_advanced"
        class="grid grid-cols-2 gap-x-6 gap-y-2 pb-2 pt-5 sm:grid-cols-3 lg:grid-cols-4"
      >
        <.input
          field={@advanced_form[:min_reposts]}
          id="filter-min-reposts"
          type="number"
          label="Minimum reposts"
          min="0"
          step="1"
          placeholder="Any"
          phx-debounce="250"
        />
        <.input
          field={@advanced_form[:min_replies]}
          id="filter-min-replies"
          type="number"
          label="Minimum replies"
          min="0"
          step="1"
          placeholder="Any"
          phx-debounce="250"
        />
        <.input
          field={@advanced_form[:min_bookmarks]}
          id="filter-min-bookmarks"
          type="number"
          label="Minimum bookmarks"
          min="0"
          step="1"
          placeholder="Any"
          phx-debounce="250"
        />
        <.input
          field={@advanced_form[:min_views]}
          id="filter-min-views"
          type="number"
          label="Minimum views"
          min="0"
          step="1"
          placeholder="Any"
          phx-debounce="250"
        />
        <.input
          field={@advanced_form[:min_length]}
          id="filter-min-length"
          type="number"
          label="Minimum characters"
          min="0"
          step="1"
          placeholder="Any"
          phx-debounce="250"
        />
        <.input field={@advanced_form[:date_from]} id="filter-date-from" type="date" label="From" />
        <.input field={@advanced_form[:date_to]} id="filter-date-to" type="date" label="To" />

        <div class="flex items-end pb-3">
          <button
            :if={advanced_filter_count(@advanced_filters) > 0}
            id="reset-advanced-filters"
            type="button"
            phx-click="reset_advanced"
            class="act text-xs"
          >
            Clear advanced filters
          </button>
        </div>
      </.form>
    </details>

    <div class="mb-6 flex flex-wrap items-center gap-5 border-y border-border py-3 text-xs">
      <span class="text-faint">Sort</span>
      <button
        :for={{value, label} <- [{"engagement", "Engagement"}, {"outlier", "Outlier"}]}
        id={"sort-#{value}"}
        phx-click="set_sort"
        phx-value-sort={value}
        class={if @sort == value, do: "act-key", else: "act"}
        aria-pressed={to_string(@sort == value)}
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

    <div
      :if={@corpus_size > 0 and @results == []}
      id="inspiration-filter-empty"
      class="py-16 text-center"
    >
      <p :if={@invalid_date_range} class="text-muted-foreground">
        The custom date range ends before it starts. Move either date to search it.
      </p>
      <p :if={!@invalid_date_range} class="text-muted-foreground">
        Nothing matched this combination: <span class="text-foreground">{@empty_filter_summary}</span>.
        Remove one filter to widen the library.
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

        <:meta :if={@show_outliers}>
          <span
            :if={is_nil(post.outlier_score)}
            id={"outlier-unavailable-#{post.id}"}
            class="text-[10px] text-faint"
            title={"At least #{Corpus.min_baseline_sample()} posts in this follower band are needed for an outlier score"}
          >
            Not enough comparable posts
          </span>
          <span
            :if={is_number(post.outlier_score) and post.outlier_score >= 2.0}
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

  defp assign_advanced(socket, filters) do
    socket
    |> assign(:advanced_filters, filters)
    |> assign(:advanced_form, to_form(filters, as: :filters))
  end

  defp normalize_advanced(params) do
    Map.new(@advanced_defaults, fn {key, _default} ->
      value = params |> Map.get(key, "") |> to_string() |> String.trim()
      {key, value}
    end)
  end

  defp minimum(value) do
    case Integer.parse(value || "") do
      {minimum, ""} when minimum > 0 -> minimum
      _ -> nil
    end
  end

  defp date_bounds("custom", filters, timezone) do
    {
      date_time(filters["date_from"], ~T[00:00:00], timezone),
      date_time(filters["date_to"], ~T[23:59:59], timezone)
    }
  end

  defp date_bounds(range, _filters, _timezone) do
    case Enum.find(@ranges, fn {key, _, _} -> key == range end) do
      {_, _, nil} -> {nil, nil}
      {_, _, days} -> {DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second), nil}
      nil -> {nil, nil}
    end
  end

  defp date_time(value, time, timezone) do
    with {:ok, date} <- Date.from_iso8601(value || ""),
         {:ok, datetime} <- DateTime.new(date, time, timezone, Tz.TimeZoneDatabase),
         {:ok, utc} <- DateTime.shift_zone(datetime, "Etc/UTC", Tz.TimeZoneDatabase) do
      DateTime.truncate(utc, :second)
    else
      _ -> nil
    end
  end

  defp custom_dates?(filters), do: filters["date_from"] != "" or filters["date_to"] != ""

  defp invalid_date_range?(filters) do
    with {:ok, from} <- Date.from_iso8601(filters["date_from"]),
         {:ok, to} <- Date.from_iso8601(filters["date_to"]) do
      Date.compare(from, to) == :gt
    else
      _ -> false
    end
  end

  defp advanced_filter_count(filters) do
    filters
    |> Enum.count(fn
      {key, value} when key in ["date_from", "date_to"] -> value != ""
      {_key, value} -> not is_nil(minimum(value))
    end)
  end

  defp empty_filter_summary(assigns) do
    filters = assigns.advanced_filters

    [
      query_filter_label(assigns.query),
      assigns.tab == "media" && "Media",
      date_filter_label(assigns.range, filters),
      "#{format_count(assigns.min_likes)}+ likes",
      minimum_label(filters["min_reposts"], "reposts"),
      minimum_label(filters["min_replies"], "replies"),
      minimum_label(filters["min_bookmarks"], "bookmarks"),
      minimum_label(filters["min_views"], "views"),
      minimum_label(filters["min_length"], "characters"),
      exclusion_filter_label(assigns.exclude, assigns.exclusions)
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(", ")
  end

  defp query_filter_label(query) do
    case String.trim(query) do
      "" -> nil
      query -> "search “#{query}”"
    end
  end

  defp date_filter_label("custom", %{"date_from" => from, "date_to" => to}) do
    case {date_label(from), date_label(to)} do
      {nil, nil} -> nil
      {from, nil} -> "from #{from}"
      {nil, to} -> "through #{to}"
      {from, to} -> "#{from}–#{to}"
    end
  end

  defp date_filter_label(range, _filters) do
    case Enum.find(@ranges, fn {key, _, _} -> key == range end) do
      {"all", _, _} -> nil
      {_, label, _} -> String.downcase(label)
      nil -> nil
    end
  end

  defp date_label(value) do
    case Date.from_iso8601(value || "") do
      {:ok, date} -> Calendar.strftime(date, "%-d %b %Y")
      _ -> nil
    end
  end

  defp minimum_label(value, noun) do
    case minimum(value) do
      nil -> nil
      minimum -> "#{format_count(minimum)}+ #{noun}"
    end
  end

  defp exclusion_filter_label([], _categories), do: nil

  defp exclusion_filter_label(excluded, categories) do
    labels =
      categories
      |> Enum.filter(&(&1.key in excluded))
      |> Enum.map(&String.downcase(&1.label))

    "hiding #{Enum.join(labels, ", ")}"
  end
end
