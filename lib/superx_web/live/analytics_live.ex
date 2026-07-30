defmodule SuperXWeb.AnalyticsLive do
  @moduledoc """
  Account metrics: headline figures, a follower trend, and the posting
  streak heatmap.
  """

  use SuperXWeb, :live_view

  alias SuperX.Analytics

  @ranges [{7, "7 days"}, {30, "30 days"}, {90, "90 days"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Analytics")
     |> assign(:days, 30)
     |> assign(:ranges, @ranges)
     |> load()}
  end

  defp load(socket) do
    account = socket.assigns.current_x_account

    socket
    |> assign(:summary, Analytics.summary(account, socket.assigns.days))
    |> assign(:activity, Analytics.posting_activity(account, 182))
    |> assign(:streak, Analytics.current_streak(account))
    |> assign(:recent, Analytics.recent_posts(account, 5))
  end

  @impl true
  def handle_event("set_range", %{"days" => days}, socket) do
    {:noreply, socket |> assign(:days, String.to_integer(days)) |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header title="Analytics" description={"Last #{@days} days."}>
      <:action>
        <div class="flex gap-4 text-xs">
          <button
            :for={{days, label} <- @ranges}
            phx-click="set_range"
            phx-value-days={days}
            class={if @days == days, do: "act-key", else: "act"}
          >
            {label}
          </button>
        </div>
      </:action>
    </Layouts.page_header>

    <div class="mb-9 grid grid-cols-2 gap-px border-t border-border bg-border lg:grid-cols-4">
      <.metric label="Followers" value={@summary.followers} change={@summary.followers_change} />
      <.metric label="Posts" value={@summary.posts} />
      <.metric label="Impressions" value={@summary.impressions} />
      <.metric label="Engagements" value={@summary.engagements} />
    </div>

    <section class="border-t border-border pt-6">
      <div class="flex items-baseline justify-between">
        <h2 class="text-[15px] font-semibold">
          <span :if={@streak > 0}>{@streak}-day streak</span>
          <span :if={@streak == 0}>No streak yet</span>
        </h2>
        <span class="nb-mono text-[11px] text-faint">last 26 weeks</span>
      </div>

      <.heatmap activity={@activity} />
    </section>

    <section :if={@summary.series != []} class="mt-9 border-t border-border pt-6">
      <div class="flex items-baseline justify-between">
        <h2 class="text-[15px] font-semibold">Followers</h2>
        <span class="nb-mono text-[11px] text-faint">
          {format_count(first_value(@summary.series))} → {format_count(@summary.followers)}
        </span>
      </div>
      <.sparkline series={@summary.series} />
    </section>

    <div :if={@summary.series == []} class="py-16 text-center">
      <p class="text-muted-foreground">
        No history yet. SuperX records a snapshot each night — check back tomorrow.
      </p>
    </div>

    <section :if={@recent != []} class="mt-9 border-t border-border pt-6">
      <div class="flex items-baseline justify-between">
        <h2 class="text-[15px] font-semibold">Recently published</h2>
        <.link navigate={~p"/queue?tab=posted"} class="act text-xs">All posts</.link>
      </div>

      <div class="mt-4 flex flex-col gap-3">
        <.post
          :for={post <- @recent}
          author={author(@current_x_account)}
          segments={segments(post)}
        >
          <:meta>{ago(post.published_at)}</:meta>

          <:actions>
            <a :if={post.permalink} href={post.permalink} target="_blank" rel="noopener" class="act">
              View on 𝕏
            </a>
          </:actions>
        </.post>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :change, :integer, default: nil

  defp metric(assigns) do
    ~H"""
    <div class="bg-background px-5 py-4">
      <p class="text-[11px] text-faint">{@label}</p>
      <p class="nb-display mt-1 text-[1.875rem] font-semibold leading-[1.1] tracking-[-0.035em] tabular-nums">
        {format_count(@value)}
      </p>
      <p
        :if={@change && @change != 0}
        class={["nb-mono mt-0.5 text-[11px]", if(@change > 0, do: "text-success", else: "text-faint")]}
      >
        {if @change > 0, do: "+", else: ""}{@change}
      </p>
    </div>
    """
  end

  defp first_value([%{followers: followers} | _]), do: followers
  defp first_value(_), do: 0

  attr :activity, :map, required: true

  defp heatmap(assigns) do
    today = Date.utc_today()
    # Start on the Sunday at or before the beginning of the window, so
    # every column is a full week.
    start = Date.add(today, -181)
    start = Date.add(start, -(Date.day_of_week(start, :sunday) - 1))

    weeks =
      start
      |> Stream.iterate(&Date.add(&1, 7))
      |> Enum.take_while(&(Date.compare(&1, today) != :gt))
      |> Enum.map(fn week_start ->
        Enum.map(0..6, fn offset ->
          date = Date.add(week_start, offset)
          {date, Map.get(assigns.activity, date, 0), Date.compare(date, today) != :gt}
        end)
      end)

    assigns = assign(assigns, :weeks, weeks)

    ~H"""
    <div class="mt-4 overflow-x-auto">
      <div class="flex gap-[3px]">
        <div :for={week <- @weeks} class="flex flex-col gap-[3px]">
          <div
            :for={{date, count, in_range} <- week}
            class="size-[11px] rounded-[2px]"
            style={"background-color: #{cell_color(count, in_range)}"}
            title={"#{Calendar.strftime(date, "%-d %b %Y")}: #{count} post(s)"}
          />
        </div>
      </div>
    </div>
    """
  end

  # Four steps is enough to read density without implying false precision.
  # Empty days are a hairline wash, not a filled tile — the grid should read
  # as paper with marks on it.
  defp cell_color(_count, false), do: "transparent"
  defp cell_color(0, _), do: "var(--muted)"
  defp cell_color(1, _), do: "color-mix(in oklab, var(--primary) 30%, transparent)"
  defp cell_color(2, _), do: "color-mix(in oklab, var(--primary) 60%, transparent)"
  defp cell_color(_, _), do: "var(--primary)"

  attr :series, :list, required: true

  defp sparkline(assigns) do
    values = Enum.map(assigns.series, & &1.followers)
    min = Enum.min(values, fn -> 0 end)
    max = Enum.max(values, fn -> 1 end)
    span = max(max - min, 1)
    count = max(length(values) - 1, 1)

    points =
      values
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {value, index} ->
        x = index / count * 100
        y = 100 - (value - min) / span * 100
        "#{Float.round(x, 2)},#{Float.round(y * 1.0, 2)}"
      end)

    assigns = assign(assigns, points: points, min: min, max: max)

    ~H"""
    <div class="mt-4">
      <svg viewBox="0 0 100 100" preserveAspectRatio="none" class="h-32 w-full" role="img"
           aria-label={"Follower trend from #{@min} to #{@max}"}>
        <defs>
          <linearGradient id="follower-fade" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="var(--primary)" stop-opacity="0.16" />
            <stop offset="100%" stop-color="var(--primary)" stop-opacity="0" />
          </linearGradient>
        </defs>

        <polygon points={"0,100 " <> @points <> " 100,100"} fill="url(#follower-fade)" />

        <polyline
          points={@points}
          fill="none"
          stroke="var(--primary)"
          stroke-width="1.5"
          vector-effect="non-scaling-stroke"
          stroke-linejoin="round"
          stroke-linecap="round"
        />
      </svg>
    </div>
    """
  end

  defp format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_count(n) when n >= 10_000, do: "#{round(n / 1_000)}K"
  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n), do: to_string(n)
end
