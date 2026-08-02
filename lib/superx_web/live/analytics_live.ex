defmodule SuperXWeb.AnalyticsLive do
  @moduledoc """
  Account metrics with honest boundaries around inferred follower gain,
  user-supplied history, and the deliberately narrow public summary.
  """

  use SuperXWeb, :live_view

  alias SuperX.Analytics
  alias SuperX.Content
  alias SuperX.Content.{Post, Writer}

  @ranges [{7, "7 days"}, {30, "30 days"}, {90, "90 days"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Analytics")
     |> assign(:days, 30)
     |> assign(:ranges, @ranges)
     |> assign(:remixing, nil)
     |> assign(:import_report, nil)
     |> allow_upload(:history,
       accept: ~w(.csv),
       max_entries: 1,
       max_file_size: 5_000_000,
       auto_upload: true
     )
     |> load()}
  end

  defp load(socket) do
    account = socket.assigns.current_x_account
    {from, to} = Analytics.date_window(socket.assigns.days)
    share = Analytics.get_share(account)

    socket
    |> assign(:summary, Analytics.summary(account, socket.assigns.days))
    |> assign(:follower_gain, Analytics.follower_gain_posts(account, from, to, 5))
    |> assign(:activity, Analytics.posting_activity(account, 182))
    |> assign(:streak, Analytics.current_streak(account))
    |> assign(:recent, Analytics.recent_posts(account, 5))
    |> assign(:share, share)
    |> assign(:share_url, share && SuperXWeb.Endpoint.url() <> ~p"/share/#{share.token}")
  end

  @impl true
  def handle_event("set_range", %{"days" => days}, socket) do
    {:noreply, socket |> assign(:days, String.to_integer(days)) |> load()}
  end

  def handle_event("create_share", _params, socket) do
    {from, to} = Analytics.date_window(socket.assigns.days)

    case Analytics.create_share(socket.assigns.current_x_account, from, to) do
      {:ok, _share} ->
        {:noreply, socket |> put_flash(:info, "Public summary ready.") |> load()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't create that public summary.")}
    end
  end

  def handle_event("revoke_share", _params, socket) do
    :ok = Analytics.revoke_share(socket.assigns.current_x_account)
    {:noreply, socket |> put_flash(:info, "Public summary turned off.") |> load()}
  end

  def handle_event("import_history", _params, socket) do
    uploads =
      consume_uploaded_entries(socket, :history, fn %{path: path}, _entry -> File.read(path) end)

    case uploads do
      [csv] -> import_history(socket, csv)
      [] -> {:noreply, put_flash(socket, :error, "Choose an X analytics CSV first.")}
    end
  end

  def handle_event("remix", _params, %{assigns: %{remixing: id}} = socket)
      when not is_nil(id),
      do: {:noreply, socket}

  def handle_event("remix", %{"id" => id}, socket) do
    case Content.get_post(socket.assigns.current_user, id) do
      %Post{status: "posted"} = post ->
        parent = self()
        user = socket.assigns.current_user
        account = socket.assigns.current_x_account

        Task.Supervisor.start_child(SuperX.TaskSupervisor, fn ->
          result = Writer.remix(user, account, post)
          send(parent, {:remixed, post.id, result})
        end)

        {:noreply, assign(socket, :remixing, post.id)}

      _ ->
        {:noreply, put_flash(socket, :error, "That published post is no longer available.")}
    end
  end

  @impl true
  def handle_info({:remixed, _id, {:ok, _generation}}, socket) do
    send(self(), :refresh_quota)

    {:noreply,
     socket
     |> assign(:remixing, nil)
     |> put_flash(:info, "Fresh variant ready.")
     |> push_navigate(to: ~p"/ready-to-post")}
  end

  def handle_info({:remixed, _id, {:error, :quota_exceeded, _details}}, socket) do
    {:noreply,
     socket
     |> assign(:remixing, nil)
     |> put_flash(:error, "You're out of AI credits for this window.")}
  end

  def handle_info({:remixed, _id, {:error, reason}}, socket) do
    require Logger
    Logger.warning("Post remix failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:remixing, nil)
     |> put_flash(:error, "Couldn't write a fresh variant just now.")}
  end

  defp import_history(socket, csv) do
    case Analytics.import_history(socket.assigns.current_x_account, csv) do
      {:ok, report} ->
        {:noreply,
         socket
         |> assign(:import_report, report)
         |> put_flash(:info, "History import finished.")
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, import_error(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header title="Analytics" description={"Last #{@days} days."}>
      <:action>
        <div class="flex flex-col items-end gap-2 text-xs">
          <div class="flex gap-4">
            <button
              :for={{days, label} <- @ranges}
              phx-click="set_range"
              phx-value-days={days}
              class={if @days == days, do: "act-key", else: "act"}
            >
              {label}
            </button>
          </div>
          <button phx-click="create_share" class="act">
            {if @share, do: "Replace shared view", else: "Share this view"}
          </button>
        </div>
      </:action>
    </Layouts.page_header>

    <section :if={@share} id="analytics-share" class="mb-9 border-y border-border py-4">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-baseline sm:justify-between">
        <div class="min-w-0">
          <p class="nb-eyebrow">Public summary</p>
          <a
            href={@share_url}
            target="_blank"
            rel="noopener"
            class="act mt-1 block truncate text-xs"
          >
            {@share_url}
          </a>
          <p class="mt-1 text-[11px] text-faint">
            {Calendar.strftime(@share.from_date, "%-d %b %Y")}–{Calendar.strftime(
              @share.to_date,
              "%-d %b %Y"
            )}
          </p>
        </div>
        <button phx-click="revoke_share" class="act-danger shrink-0 text-xs">
          Turn off
        </button>
      </div>
    </section>

    <%!-- A hard 0 beside three em-dashes reads as "you have no followers"
          rather than "nothing recorded yet", so an unrecorded follower
          count is dashed like every other metric on the row. --%>
    <div class="mb-9 grid grid-cols-2 gap-px border-t border-border bg-border lg:grid-cols-4">
      <.metric
        id="analytics-metric-followers"
        label="Followers"
        value={recorded_value(@summary.followers, @summary.coverage)}
        change={@summary.followers_change}
        change_known={@summary.follower_change_available?}
        note={if(@summary.coverage.recorded == 0, do: "No snapshots")}
      />
      <.metric
        id="analytics-metric-posts"
        label="Posts"
        value={if(@summary.posts_change_available?, do: @summary.posts, else: nil)}
        note={if(!@summary.posts_change_available?, do: "Needs two snapshots")}
      />
      <.metric
        id="analytics-metric-impressions"
        label="Impressions"
        value={recorded_value(@summary.impressions, @summary.coverage)}
        note={if(@summary.coverage.recorded == 0, do: "No snapshots")}
      />
      <.metric
        id="analytics-metric-engagements"
        label="Engagements"
        value={recorded_value(@summary.engagements, @summary.coverage)}
        note={if(@summary.coverage.recorded == 0, do: "No snapshots")}
      />
    </div>

    <div
      :if={@summary.coverage.recorded > 0 and @summary.coverage.missing > 0}
      id="analytics-coverage"
      class="mb-9 border-y border-border py-4 text-[12px] leading-relaxed text-muted-foreground"
    >
      Only {@summary.coverage.recorded} of {@summary.coverage.expected} daily snapshots were recorded in this window. Impression and engagement totals cover recorded dates only; missing days are unknown, not zero.
      <span :if={!@summary.follower_change_available?}>
        Follower and post changes need at least two recorded totals.
      </span>
      <span :if={@summary.follower_change_available?}>
        Follower change uses the first and last recorded follower totals. Post change appears only when two post totals are available.
      </span>
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

    <section id="follower-gain" class="mt-9 border-t border-border pt-6">
      <div class="flex flex-col gap-2 sm:flex-row sm:items-baseline sm:justify-between">
        <h2 class="text-[15px] font-semibold">Posts associated with follower gain</h2>
        <span class="text-[11px] text-faint">Estimated, not measured per post</span>
      </div>
      <p class="mt-2 max-w-[64ch] text-[12px] leading-relaxed text-muted-foreground">
        Each positive change between adjacent daily snapshots is shared evenly across posts published on the UTC day between them.
      </p>

      <div :if={@follower_gain == []} class="py-10 text-center">
        <p class="text-muted-foreground">
          No positive follower days line up with a published post in this window.
        </p>
      </div>

      <div :if={@follower_gain != []} class="mt-4 flex flex-col gap-3">
        <.post
          :for={entry <- @follower_gain}
          author={author(@current_x_account)}
          segments={segments(entry.post)}
        >
          <:meta>
            <span class="nb-mono">{estimated_gain(entry.estimated_followers)} followers</span>
            · {Calendar.strftime(DateTime.to_date(entry.post.published_at), "%-d %b")}
          </:meta>
          <:actions>
            <button
              phx-click="remix"
              phx-value-id={entry.post.id}
              class="act-key"
              disabled={not is_nil(@remixing)}
            >
              {if @remixing == entry.post.id, do: "Writing…", else: "Remix"}
            </button>
            <a
              :if={entry.post.permalink}
              href={entry.post.permalink}
              target="_blank"
              rel="noopener"
              class="act"
            >
              View on 𝕏
            </a>
          </:actions>
        </.post>
      </div>
    </section>

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
            <button
              phx-click="remix"
              phx-value-id={post.id}
              class="act-key"
              disabled={not is_nil(@remixing)}
            >
              {if @remixing == post.id, do: "Writing…", else: "Remix"}
            </button>
            <a :if={post.permalink} href={post.permalink} target="_blank" rel="noopener" class="act">
              View on 𝕏
            </a>
          </:actions>
        </.post>
      </div>
    </section>

    <section id="analytics-history-import" class="mt-9 border-t border-border pt-6">
      <div class="grid grid-cols-1 gap-6 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-start">
        <div>
          <h2 class="text-[15px] font-semibold">Import history</h2>
          <p class="mt-2 max-w-[64ch] text-[12px] leading-relaxed text-muted-foreground">
            Upload the CSV you downloaded from X Analytics. SuperX fills missing dates and leaves every snapshot it collected itself untouched.
          </p>
        </div>

        <form
          id="analytics-history-form"
          phx-submit="import_history"
          class="flex items-center gap-4 text-xs"
        >
          <label class="act cursor-pointer">
            {history_file_label(@uploads.history)}
            <.live_file_input upload={@uploads.history} class="sr-only" />
          </label>
          <button
            type="submit"
            class="act-key"
            disabled={!history_upload_ready?(@uploads.history)}
          >
            Import
          </button>
        </form>
      </div>

      <p
        :for={error <- upload_errors(@uploads.history)}
        class="mt-2 text-[11px] text-destructive"
      >
        {history_upload_error(error)}
      </p>

      <div :if={@import_report} id="analytics-import-report" class="mt-9 border-t border-border pt-4">
        <p>{imported_summary(@import_report)}</p>
        <p class="mt-1 text-[12px] text-muted-foreground">{skipped_summary(@import_report)}</p>
        <p
          :if={@import_report.ignored_columns != []}
          class="mt-1 text-[12px] text-muted-foreground"
        >
          {ignored_columns_summary(@import_report.ignored_columns)}
        </p>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :change, :integer, default: nil
  attr :change_known, :any, default: nil
  attr :note, :string, default: nil

  defp metric(assigns) do
    ~H"""
    <div id={@id} class="bg-background px-5 py-4">
      <p class="text-[11px] text-faint">{@label}</p>
      <p class="nb-display mt-1 text-[1.875rem] font-semibold leading-[1.1] tracking-[-0.035em] tabular-nums">
        {format_count(@value)}
      </p>
      <p
        :if={@change_known == true}
        class={["nb-mono mt-0.5 text-[11px]", if(@change > 0, do: "text-success", else: "text-faint")]}
      >
        <%= cond do %>
          <% @change > 0 -> %>
            +{@change}
          <% @change < 0 -> %>
            {@change}
          <% true -> %>
            No change
        <% end %>
      </p>
      <%!-- "No snapshots" already says why there is no change to show;
            printing both stacks two apologies under one dash. --%>
      <p :if={@change_known == false and is_nil(@note)} class="mt-0.5 text-[11px] text-faint">
        Change unavailable
      </p>
      <p :if={@note} class="mt-0.5 text-[11px] text-faint">{@note}</p>
    </div>
    """
  end

  defp first_value([%{followers: followers} | _]), do: followers
  defp first_value(_), do: 0

  defp estimated_gain(estimate) when estimate == trunc(estimate), do: "≈ +#{trunc(estimate)}"
  defp estimated_gain(estimate), do: "≈ +#{Float.round(estimate, 1)}"

  defp recorded_value(_value, %{recorded: 0}), do: nil
  defp recorded_value(value, _coverage), do: value

  defp history_file_label(%{entries: [entry | _]}), do: entry.client_name
  defp history_file_label(_upload), do: "Choose CSV"

  defp history_upload_ready?(%{entries: [entry]}), do: entry.done?
  defp history_upload_ready?(_upload), do: false

  defp history_upload_error(:too_large), do: "The CSV must be 5 MB or smaller."
  defp history_upload_error(:too_many_files), do: "Choose one CSV at a time."
  defp history_upload_error(:not_accepted), do: "Choose a CSV downloaded from X Analytics."
  defp history_upload_error(_error), do: "That CSV could not be uploaded."

  defp import_error(:empty_file), do: "That CSV is empty."
  defp import_error(:missing_date), do: "That CSV has no recognised date column."

  defp import_error(:missing_followers),
    do: "That CSV has no recognised follower total, gain, or unfollow columns."

  defp import_error(:malformed_csv), do: "That CSV has an unfinished quoted field."
  defp import_error(_reason), do: "That history could not be imported."

  defp imported_summary(%{imported: 0, recognised: recognised}) do
    "No new dates imported. Recognised #{metric_names(recognised)}."
  end

  defp imported_summary(report) do
    range =
      if report.imported_from == report.imported_to do
        Calendar.strftime(report.imported_from, "%-d %b %Y")
      else
        "#{Calendar.strftime(report.imported_from, "%-d %b %Y")}–#{Calendar.strftime(report.imported_to, "%-d %b %Y")}"
      end

    "Imported #{report.imported} #{if report.imported == 1, do: "date", else: "dates"} (#{range}): #{metric_names(report.recognised)}."
  end

  defp skipped_summary(report) do
    "Skipped #{report.skipped_existing} already recorded, #{report.skipped_duplicate} duplicate, and #{report.skipped_invalid} invalid or unanchored #{if report.skipped_invalid == 1, do: "row", else: "rows"}."
  end

  defp ignored_columns_summary([column]), do: "Ignored unrecognised column: #{column}."

  defp ignored_columns_summary(columns) do
    "Ignored unrecognised columns: #{Enum.join(columns, ", ")}."
  end

  defp metric_names(metrics) do
    metrics
    |> Enum.map(fn
      :profile_clicks -> "profile visits"
      metric -> metric |> Atom.to_string() |> String.replace("_", " ")
    end)
    |> Enum.join(", ")
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
      <svg
        viewBox="0 0 100 100"
        preserveAspectRatio="none"
        class="h-32 w-full"
        role="img"
        aria-label={"Follower trend from #{@min} to #{@max}"}
      >
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

  defp format_count(nil), do: "—"
  defp format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_count(n) when n >= 10_000, do: "#{round(n / 1_000)}K"
  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n), do: to_string(n)
end
