defmodule SuperXWeb.AnalyticsShareHTML do
  @moduledoc """
  The public analytics capability exposes the shared figures without the
  signed-in shell, navigation, posts, or account controls.
  """

  use SuperXWeb, :html

  embed_templates "analytics_share_html/*"

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :change, :integer, default: nil

  def metric(assigns) do
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

  attr :series, :list, required: true

  def sparkline(assigns) do
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
      <svg
        viewBox="0 0 100 100"
        preserveAspectRatio="none"
        class="h-32 w-full"
        role="img"
        aria-label={"Follower trend from #{@min} to #{@max}"}
      >
        <defs>
          <linearGradient id="shared-follower-fade" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="var(--primary)" stop-opacity="0.16" />
            <stop offset="100%" stop-color="var(--primary)" stop-opacity="0" />
          </linearGradient>
        </defs>

        <polygon points={"0,100 " <> @points <> " 100,100"} fill="url(#shared-follower-fade)" />
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

  def format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def format_count(n) when n >= 10_000, do: "#{round(n / 1_000)}K"
  def format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  def format_count(n), do: to_string(n)
end
