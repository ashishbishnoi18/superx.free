defmodule SuperXWeb.ApiRateLimit do
  @moduledoc """
  A reusable per-user fixed-window limiter for authenticated interfaces.

  The plan is resolved for every request, so upgrades and downgrades change
  the allowance without rebuilding the pipeline. One user is the boundary
  rather than one credential: issuing another API token or reaching the same
  operations through MCP must not multiply the plan's allowance.
  """

  use GenServer

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  alias SuperX.Accounts.User
  alias SuperX.Billing
  alias SuperX.Billing.Plan

  @minute_seconds 60
  @day_seconds 86_400

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(state) when is_map(state) do
    # Counters deliberately reset on restart. SuperX runs on one node, and
    # accepting a brief fresh allowance is preferable to adding a durable
    # write to Postgres on every request solely for abuse protection.
    {:ok, state}
  end

  def init(opts) when is_list(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: %User{} = user}} = conn, _opts) do
    limit = user |> Billing.tier() |> Plan.limit(:api_requests_minute)

    case take(user.id, limit) do
      {:ok, rate} -> put_rate_headers(conn, rate)
      {:error, rate} -> rate_limited(conn, rate)
    end
  end

  def call(_conn, _opts) do
    raise ArgumentError, "ApiRateLimit must run after a plug that assigns :current_user"
  end

  @doc "The current node's minute and UTC-day counts for an Accounts meter."
  def usage(%User{id: user_id}), do: GenServer.call(__MODULE__, {:usage, user_id, now()})

  @doc false
  def take(user_id, limit, now \\ now()) when is_integer(limit) and limit >= 0 do
    GenServer.call(__MODULE__, {:take, user_id, limit, now})
  end

  @impl true
  def handle_call({:take, user_id, limit, now}, _from, state) do
    usage = current_usage(Map.get(state, user_id), now)
    requests_today = usage.requests_today + 1
    allowed? = usage.used_minute < limit
    used_minute = if allowed?, do: usage.used_minute + 1, else: usage.used_minute

    updated = %{
      minute_started_at: usage.minute_started_at,
      used_minute: used_minute,
      day: day_window(now),
      requests_today: requests_today
    }

    rate = rate_data(updated, limit, now)
    reply = if allowed?, do: {:ok, rate}, else: {:error, rate}

    {:reply, reply, Map.put(state, user_id, updated)}
  end

  def handle_call({:usage, user_id, now}, _from, state) do
    usage = current_usage(Map.get(state, user_id), now)
    {:reply, Map.take(usage, [:used_minute, :requests_today]), state}
  end

  defp current_usage(nil, now) do
    %{
      minute_started_at: now,
      used_minute: 0,
      day: day_window(now),
      requests_today: 0
    }
  end

  defp current_usage(stored, now) do
    stored
    |> roll_minute(now)
    |> roll_day(now)
  end

  defp roll_minute(%{minute_started_at: started_at} = usage, now)
       when now >= started_at and now < started_at + @minute_seconds,
       do: usage

  defp roll_minute(usage, now),
    do: %{usage | minute_started_at: now, used_minute: 0}

  defp roll_day(%{day: day} = usage, now) when day == div(now, @day_seconds), do: usage

  defp roll_day(usage, now),
    do: %{usage | day: day_window(now), requests_today: 0}

  defp rate_data(usage, limit, now) do
    reset_after = max(usage.minute_started_at + @minute_seconds - now, 1)

    %{
      limit: limit,
      remaining: max(limit - usage.used_minute, 0),
      reset_after: reset_after,
      requests_today: usage.requests_today
    }
  end

  defp put_rate_headers(conn, rate) do
    conn
    |> put_resp_header("ratelimit-limit", Integer.to_string(rate.limit))
    |> put_resp_header("ratelimit-remaining", Integer.to_string(rate.remaining))
    |> put_resp_header("ratelimit-reset", Integer.to_string(rate.reset_after))
  end

  defp rate_limited(conn, rate) do
    conn
    |> put_rate_headers(rate)
    |> put_resp_header("retry-after", Integer.to_string(rate.reset_after))
    |> put_status(:too_many_requests)
    |> json(%{error: "Rate limit exceeded. Try again after #{rate.reset_after} seconds."})
    |> halt()
  end

  defp day_window(now), do: div(now, @day_seconds)
  defp now, do: System.system_time(:second)
end
