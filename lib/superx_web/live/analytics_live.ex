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
  end

  @impl true
  def handle_event("set_range", %{"days" => days}, socket) do
    {:noreply, socket |> assign(:days, String.to_integer(days)) |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <h1 class="text-2xl font-bold tracking-tight">Analytics</h1>

        <form phx-change="set_range">
          <select name="days" class="select w-auto py-1.5 text-sm">
            <option :for={{days, label} <- @ranges} value={days} selected={@days == days}>
              {label}
            </option>
          </select>
        </form>
      </div>

      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.metric
          label="Followers"
          value={@summary.followers}
          change={@summary.followers_change}
        />
        <.metric label="Posts" value={@summary.posts} />
        <.metric label="Impressions" value={@summary.impressions} />
        <.metric label="Engagements" value={@summary.engagements} />
      </div>

      <section class="card p-5">
        <div class="flex items-baseline justify-between">
          <h2 class="font-semibold">
            <span :if={@streak > 0}>
              {@streak}-day streak
            </span>
            <span :if={@streak == 0}>No streak yet</span>
          </h2>
          <p class="text-xs" style="color: var(--text-muted)">Last 26 weeks</p>
        </div>

        <.heatmap activity={@activity} />
      </section>

      <section :if={@summary.series != []} class="card p-5">
        <h2 class="font-semibold">Followers</h2>
        <.sparkline series={@summary.series} />
      </section>

      <div :if={@summary.series == []} class="card p-10 text-center">
        <p class="text-sm" style="color: var(--text-secondary)">
          No history yet. SuperX records a snapshot each night — check back tomorrow.
        </p>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :change, :integer, default: nil

  defp metric(assigns) do
    ~H"""
    <div class="card p-4">
      <p class="text-xs font-semibold uppercase tracking-wide" style="color: var(--text-muted)">
        {@label}
      </p>
      <p class="mt-1.5 text-3xl font-bold tabular-nums">{format_count(@value)}</p>
      <p
        :if={@change && @change != 0}
        class={["mt-1 text-xs font-medium tabular-nums", @change > 0 && "text-ember-600"]}
        style={@change < 0 && "color: var(--text-muted)"}
      >
        {if @change > 0, do: "+", else: ""}{@change} in range
      </p>
    </div>
    """
  end

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
  defp cell_color(_count, false), do: "transparent"
  defp cell_color(0, _), do: "var(--surface-sunken)"
  defp cell_color(1, _), do: "var(--color-ember-200)"
  defp cell_color(2, _), do: "var(--color-ember-400)"
  defp cell_color(_, _), do: "var(--color-ember-600)"

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
      <svg viewBox="0 0 100 100" preserveAspectRatio="none" class="h-28 w-full">
        <polyline
          points={@points}
          fill="none"
          stroke="var(--color-ember-500)"
          stroke-width="1.5"
          vector-effect="non-scaling-stroke"
          stroke-linejoin="round"
          stroke-linecap="round"
        />
      </svg>
      <div class="mt-1 flex justify-between text-xs tabular-nums" style="color: var(--text-muted)">
        <span>{format_count(@min)}</span>
        <span>{format_count(@max)}</span>
      </div>
    </div>
    """
  end

  defp format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_count(n) when n >= 10_000, do: "#{round(n / 1_000)}K"
  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n), do: to_string(n)
end
