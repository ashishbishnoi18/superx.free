defmodule SuperX.XChat do
  @moduledoc """
  Runs X's Chat XDK outside the BEAM and exposes only its crypto boundary.

  X does not publish enough of the encrypted-message scheme to reproduce it
  safely. A long-lived Node process loads the official WASM engine and speaks
  correlated, line-delimited JSON over an Erlang Port. HTTP remains in
  `SuperX.X`, so OAuth tokens never cross this boundary.

  Private key blobs are permitted here because SuperX is self-hosted: the
  operator's machine holds that same operator's X identity and OAuth tokens.
  This is not a safe design for hosting other people's SuperX accounts. X
  explicitly warns UI and hosted applications not to collect end-user private
  keys.

  The worker is optional. Missing Node or npm files leave this process idle and
  the rest of SuperX, including legacy DMs, keeps working.
  """

  use GenServer

  require Logger

  @call_timeout :timer.minutes(2)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc "Whether the official Chat XDK worker is available."
  def available?(server \\ __MODULE__) do
    GenServer.call(server, :available?)
  catch
    :exit, _reason -> false
  end

  @doc "Generates an XChat identity and its public registration payload."
  def register_keys(server \\ __MODULE__) do
    request(server, "register_keys", %{})
  end

  @doc "Verifies and decrypts a batch of raw Chat events."
  def decrypt_events(params, server \\ __MODULE__) when is_map(params) do
    request(server, "decrypt_events", params)
  end

  @doc "Encrypts and signs a message after rebuilding its conversation key from history."
  def encrypt_message(params, server \\ __MODULE__) when is_map(params) do
    request(server, "encrypt_message", params)
  end

  @impl true
  def init(opts) do
    binary = opts[:binary] || configured_binary()
    script = opts[:script] || configured_script()

    state = %{
      binary: binary,
      script: script,
      port: nil,
      pending: %{},
      buffer: "",
      configured: false,
      seq: 0
    }

    case unavailable_reason(binary, script) do
      nil ->
        Process.flag(:trap_exit, true)
        {:ok, open(state)}

      reason ->
        # Optional for anyone who has not switched DMs on, but an operator who
        # has is expecting an inbox. Staying at debug hid a broken path here
        # behind a sync that reported success and returned nothing.
        if dms_enabled?() do
          Logger.warning("XChat worker unavailable, so encrypted DMs will not sync: #{reason}")
        else
          Logger.debug("Optional XChat worker disabled: #{reason}")
        end

        {:ok, state}
    end
  end

  @impl true
  def handle_call(:available?, _from, state) do
    {:reply, state.configured, state}
  end

  def handle_call({:request, _op, _params}, _from, %{port: nil} = state) do
    {:reply, {:error, :xchat_unavailable}, state}
  end

  def handle_call({:request, op, params}, from, state) do
    id = "req-#{state.seq}"
    payload = Jason.encode!(%{id: id, op: op, params: params}) <> "\n"
    true = Port.command(state.port, payload)

    {:noreply,
     %{
       state
       | pending: Map.put(state.pending, id, from),
         seq: state.seq + 1
     }}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {lines, buffer} = split_lines(state.buffer <> chunk)
    state = Enum.reduce(lines, %{state | buffer: buffer}, &handle_line/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("XChat worker exited with status #{status}; restarting")

    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, :xchat_worker_exited})
    end)

    Process.send_after(self(), :reopen, 5_000)

    {:noreply, %{state | port: nil, pending: %{}, buffer: "", configured: false}}
  end

  def handle_info(:reopen, %{port: nil} = state) do
    case unavailable_reason(state.binary, state.script) do
      nil -> {:noreply, open(state)}
      _reason -> {:noreply, state}
    end
  end

  def handle_info(:reopen, state), do: {:noreply, state}
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp request(server, op, params) do
    GenServer.call(server, {:request, op, params}, @call_timeout)
  catch
    :exit, {:timeout, _details} -> {:error, :xchat_timeout}
    :exit, {:noproc, _details} -> {:error, :xchat_unavailable}
  end

  defp open(state) do
    port =
      Port.open({:spawn_executable, state.binary}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: [state.script]
      ])

    # The Port buffers requests while WASM loads. Treating that short window
    # as disabled would make the first scheduled sync miss a healthy worker.
    %{state | port: port, buffer: "", configured: true}
  end

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

      {:error, _reason} ->
        Logger.warning("XChat worker emitted a non-JSON response")
        state
    end
  end

  defp dispatch(%{"type" => "ready", "data" => data}, state) do
    configured = data["configured"] == true

    unless configured do
      Logger.debug("Optional XChat worker could not load the Chat XDK")
    end

    %{state | configured: configured}
  end

  defp dispatch(%{"type" => "done", "id" => id, "data" => data}, state) do
    reply(id, {:ok, data}, state)
  end

  defp dispatch(%{"type" => "error", "id" => id, "message" => message}, state) do
    reply(id, {:error, {:xchat, message}}, state)
  end

  defp dispatch(_message, state), do: state

  defp reply(id, result, state) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        %{state | pending: pending}

      {from, pending} ->
        GenServer.reply(from, result)
        %{state | pending: pending}
    end
  end

  defp unavailable_reason(nil, _script), do: "Node was not found"

  defp unavailable_reason(binary, script) do
    cond do
      not File.exists?(binary) -> "Node was not found at #{binary}"
      not File.exists?(script) -> "the sidecar was not found at #{script}"
      not File.exists?(dependency_path(script)) -> "the Chat XDK npm dependency is missing"
      true -> nil
    end
  end

  defp dms_enabled? do
    Application.get_env(:superx, SuperX.X, [])[:dm_enabled] == true
  end

  defp dependency_path(script) do
    script
    |> Path.dirname()
    |> Path.join("node_modules/@xdevplatform/chat-xdk/index.js")
  end

  defp configured_binary do
    Application.get_env(:superx, __MODULE__, [])[:binary] || System.find_executable("node")
  end

  # A release boots with its working directory at `bin/`, so a CWD-relative
  # path silently resolves to `bin/xchat/sidecar.mjs` and the worker never
  # starts. Each candidate is tried in turn: the release root covers
  # production, the CWD covers `mix phx.server` from the project root.
  defp configured_script do
    Application.get_env(:superx, __MODULE__, [])[:script] ||
      Enum.find(script_candidates(), List.first(script_candidates()), &File.exists?/1)
  end

  defp script_candidates do
    [
      Path.join(to_string(:code.root_dir()), "xchat/sidecar.mjs"),
      Path.expand("xchat/sidecar.mjs")
    ]
  end
end
