defmodule SuperX.Scraper do
  @moduledoc """
  Supervises the Go read-worker and speaks its line-delimited protocol.

  The worker is a long-lived external process behind a Port. Keeping it
  alive between requests matters: it holds a guest token whose rate limit
  is shared, so respawning per request would both waste tokens and hit
  limits faster.

  Requests are correlated by id, so a caller blocked on one search does
  not receive another's items. Streaming responses are accumulated and
  returned as a list when the worker emits `done`.
  """

  use GenServer

  require Logger

  @call_timeout :timer.minutes(5)

  defmodule State do
    @moduledoc false
    defstruct [:port, :binary, pending: %{}, buffer: "", ready: false, configured: false, seq: 0]
  end

  # --- Client --------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Searches X for posts matching `query`.

  Returns `{:ok, posts}` where each post is a map ready for
  `SuperX.Content.Corpus.upsert_many/1`.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    request(
      "search",
      %{
        query: query,
        min_likes: opts[:min_likes] || 100,
        limit: opts[:limit] || 50,
        lang: opts[:lang] || "en"
      },
      opts
    )
  end

  @doc "Fetches recent posts for one handle."
  def profile(handle, opts \\ []) do
    request("profile", %{handle: handle, limit: opts[:limit] || 40}, opts)
  end

  @doc "Checks the worker is alive and configured."
  def ping(opts \\ []) do
    case request("ping", %{}, opts) do
      {:ok, _items} -> :ok
      error -> error
    end
  end

  @doc "Whether the worker reported usable credentials at startup."
  def configured?(server \\ __MODULE__) do
    GenServer.call(server, :configured?)
  catch
    :exit, _ -> false
  end

  defp request(op, params, opts) do
    server = opts[:server] || __MODULE__
    GenServer.call(server, {:request, op, params}, opts[:timeout] || @call_timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :scraper_not_running}
  end

  # --- Server --------------------------------------------------------------

  @impl true
  def init(opts) do
    binary = opts[:binary] || default_binary()

    if File.exists?(binary) do
      Process.flag(:trap_exit, true)
      {:ok, open(%State{binary: binary})}
    else
      # Not fatal: everything except corpus ingestion works without it,
      # and a self-hoster may not have built the worker yet.
      Logger.warning("Scraper binary not found at #{binary}; corpus ingestion is disabled")
      {:ok, %State{binary: binary}}
    end
  end

  defp open(%State{binary: binary} = state) do
    # Stream mode (the default): chunks arrive arbitrarily split, so we
    # reassemble lines ourselves. A packet mode would cap line length,
    # and timeline cursors are long.
    port =
      Port.open({:spawn_executable, binary}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: []
      ])

    %{state | port: port, buffer: ""}
  end

  @impl true
  def handle_call(:configured?, _from, state) do
    {:reply, state.configured, state}
  end

  def handle_call({:request, _op, _params}, _from, %State{port: nil} = state) do
    {:reply, {:error, :scraper_not_running}, state}
  end

  def handle_call({:request, op, params}, from, state) do
    id = "req-#{state.seq}"

    payload = Jason.encode!(%{id: id, op: op, params: params}) <> "\n"
    Port.command(state.port, payload)

    pending = Map.put(state.pending, id, %{from: from, items: []})

    {:noreply, %{state | pending: pending, seq: state.seq + 1}}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %State{port: port} = state) do
    {lines, buffer} = split_lines(state.buffer <> chunk)
    state = Enum.reduce(lines, %{state | buffer: buffer}, &handle_line/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %State{port: port} = state) do
    Logger.error("Scraper worker exited with status #{status}; restarting")

    # Fail everything in flight rather than leaving callers to time out.
    Enum.each(state.pending, fn {_id, %{from: from}} ->
      GenServer.reply(from, {:error, :worker_exited})
    end)

    # Backoff keeps a crash-looping binary from spinning the CPU.
    Process.send_after(self(), :reopen, 5_000)

    {:noreply, %{state | port: nil, pending: %{}, buffer: "", ready: false}}
  end

  def handle_info(:reopen, %State{port: nil} = state) do
    if File.exists?(state.binary) do
      {:noreply, open(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:reopen, state), do: {:noreply, state}

  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Protocol ------------------------------------------------------------

  defp split_lines(data) do
    case String.split(data, "\n") do
      [incomplete] -> {[], incomplete}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp handle_line("", state), do: state

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, message} ->
        dispatch(message, state)

      {:error, _} ->
        Logger.warning("Scraper emitted non-JSON: #{inspect(line)}")
        state
    end
  end

  defp dispatch(%{"type" => "ready", "data" => data}, state) do
    configured = data["configured"] == true

    unless configured do
      Logger.info("Scraper started but is not configured; set X_WEB_BEARER and X_SEARCH_PATH")
    end

    %{state | ready: true, configured: configured}
  end

  defp dispatch(%{"type" => "item", "id" => id, "data" => item}, state) do
    update_in(state.pending[id], fn
      nil -> nil
      entry -> %{entry | items: [normalize(item) | entry.items]}
    end)
  end

  defp dispatch(%{"type" => "done", "id" => id}, state) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        %{state | pending: pending}

      {%{from: from, items: items}, pending} ->
        GenServer.reply(from, {:ok, Enum.reverse(items)})
        %{state | pending: pending}
    end
  end

  defp dispatch(%{"type" => "error", "id" => id} = message, state) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        Logger.warning("Scraper error: #{message["message"]}")
        %{state | pending: pending}

      {%{from: from, items: items}, pending} ->
        # Hand back whatever streamed before the failure; partial results
        # are still worth ingesting.
        reply =
          if items == [],
            do: {:error, message["message"]},
            else: {:ok, Enum.reverse(items)}

        GenServer.reply(from, reply)
        %{state | pending: pending}
    end
  end

  defp dispatch(%{"type" => "error"} = message, state) do
    Logger.warning("Scraper error: #{message["message"]}")
    state
  end

  defp dispatch(_message, state), do: state

  # The worker emits the field names CorpusPost expects; this converts
  # them to atoms and parses the timestamp.
  defp normalize(item) do
    %{
      x_post_id: item["x_post_id"],
      author_handle: item["author_handle"],
      author_name: item["author_name"],
      author_avatar_url: item["author_avatar_url"],
      author_followers: item["author_followers"] || 0,
      author_verified: item["author_verified"] || false,
      text: item["text"],
      lang: item["lang"],
      likes: item["likes"] || 0,
      reposts: item["reposts"] || 0,
      replies: item["replies"] || 0,
      quotes: item["quotes"] || 0,
      bookmarks: item["bookmarks"] || 0,
      impressions: item["impressions"] || 0,
      posted_at: parse_time(item["posted_at"]),
      media: item["media"] || [],
      is_thread: item["is_thread"] || false,
      source: "scraper"
    }
  end

  defp parse_time(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse_time(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp default_binary do
    Application.get_env(:superx, __MODULE__, [])[:binary] ||
      Path.join(:code.priv_dir(:superx), "scraper")
  end
end
