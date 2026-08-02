defmodule SuperXWeb.SignalsLive do
  @moduledoc """
  Watch agents: what SuperX is watching on X, and who it's found.
  """

  use SuperXWeb, :live_view

  alias SuperX.Signals
  alias SuperX.Signals.Agent
  alias SuperX.Workers.SignalSweep

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Signals")
     |> assign(:running, MapSet.new())
     |> assign(:agent_form, new_agent_form())
     |> assign(:api_configured, SuperX.TwitterAPI.configured?())
     |> assign(:ai_configured, SuperX.AI.configured?())
     |> load()}
  end

  defp load(socket) do
    account = socket.assigns.current_x_account
    agents = Signals.list_agents(account)

    socket
    |> assign(:agents, agents)
    |> assign(
      :agent_list_forms,
      Map.new(agents, fn agent ->
        {agent.id, to_form(%{"contact_list_id" => agent.contact_list_id}, as: :filing)}
      end)
    )
    |> assign(:contact_lists, Signals.manual_contact_lists(account))
    |> assign(:limit, Signals.agent_limit(socket.assigns.current_user))
    |> assign(:lead_counts, Signals.lead_counts(account))
  end

  @impl true
  def handle_event("create", %{"agent" => params}, socket) do
    attrs = %{
      kind: params["kind"],
      target: params["target"],
      ideal_customer: params["ideal_customer"],
      min_score: String.to_integer(params["min_score"] || "60"),
      contact_list_id: params["contact_list_id"]
    }

    cond do
      length(socket.assigns.agents) >= socket.assigns.limit ->
        {:noreply,
         socket
         |> put_flash(:error, "Your plan includes #{socket.assigns.limit} agent(s).")
         |> push_navigate(to: ~p"/upgrade")}

      true ->
        case Signals.create_agent(socket.assigns.current_x_account, attrs) do
          {:ok, agent} ->
            socket =
              socket
              |> assign(:agent_form, new_agent_form())
              |> load()

            if socket.assigns.api_configured do
              {:noreply,
               socket
               |> start_run(agent)
               |> put_flash(:info, "Agent created. Running it now.")}
            else
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 "Agent created, but it can't run until the X read API is configured."
               )}
            end

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign(:agent_form, to_form(changeset))
             |> put_flash(:error, error_message(changeset))}
        end
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    Signals.toggle_agent(socket.assigns.current_x_account, id)
    {:noreply, load(socket)}
  end

  def handle_event(
        "set_contact_list",
        %{"agent-id" => id, "filing" => %{"contact_list_id" => contact_list_id}},
        socket
      ) do
    with %Agent{} = agent <- Signals.get_agent(socket.assigns.current_x_account, id),
         {:ok, _agent} <- Signals.update_agent(agent, %{contact_list_id: contact_list_id}) do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That list is not available.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Signals.delete_agent(socket.assigns.current_x_account, id)
    {:noreply, socket |> put_flash(:info, "Agent removed.") |> load()}
  end

  def handle_event("run", %{"id" => id}, socket) do
    cond do
      MapSet.member?(socket.assigns.running, id) ->
        {:noreply, socket}

      agent = Signals.get_agent(socket.assigns.current_x_account, id) ->
        {:noreply, start_run(socket, agent)}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:ran, id, result}, socket) do
    socket = update(socket, :running, &MapSet.delete(&1, id))

    case result do
      {:ok, 0} ->
        {:noreply, socket |> put_flash(:info, "No new matches this run.") |> load()}

      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "Found #{count} lead(s).")
         |> load()}

      {:error, :quota_exceeded, _details} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Daily lead limit reached. This agent will try again after the quota resets."
         )
         |> load()}

      {:error, reason} ->
        require Logger
        Logger.warning("Manual agent run failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "That run failed. Check the agent's target.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header
      title="Signals"
      description="Standing watches on X. Each one checks its target, scores whoever it finds against your description of a good match, and files the keepers in Contacts."
    >
      <:action>
        <.link navigate={~p"/contacts"} class="act whitespace-nowrap text-xs">
          {Map.get(@lead_counts, "all", 0)} contacts
        </.link>
      </:action>
    </Layouts.page_header>

    <p :if={!@api_configured} class="mb-8 max-w-[60ch] text-muted-foreground">
      Set <code class="nb-mono text-[12px] text-foreground">TWITTERAPI_IO_KEY</code>
      to let agents read X. They won't run without it.
    </p>

    <p :if={@api_configured and !@ai_configured} class="mb-8 max-w-[60ch] text-muted-foreground">
      Without <code class="nb-mono text-[12px] text-foreground">ANTHROPIC_API_KEY</code>
      agents can find people but can't judge whether they fit — everything comes back
      at your minimum score, unranked.
    </p>

    <div :if={@agents == []} class="border-t border-border py-10 text-center">
      <p class="text-muted-foreground">
        No agents yet. The one below finds people who just said something you'd want to answer.
      </p>
    </div>

    <div class="flex flex-col">
      <article
        :for={agent <- @agents}
        id={"signal-agent-#{agent.id}"}
        class="grid grid-cols-1 gap-7 border-b border-border py-5 first:border-t sm:grid-cols-[minmax(0,1fr)_auto]"
      >
        <div class="min-w-0">
          <p class="flex items-baseline gap-2">
            <span class={["font-medium", !agent.enabled && "text-faint line-through"]}>
              {agent.name}
            </span>
            <span class="nb-mono text-[11px] text-faint">{Agent.describes(agent)}</span>
          </p>

          <p :if={agent.ideal_customer} class="mt-1 max-w-[62ch] text-[13px] text-muted-foreground">
            Looking for: {agent.ideal_customer}
          </p>

          <p class="nb-mono mt-1.5 text-[11px] text-faint">
            {agent.leads_found} found · min score {agent.min_score} ·
            <span :if={agent.last_run_at}>last run {ago(agent.last_run_at)}</span>
            <span :if={!agent.last_run_at}>not run yet</span>
          </p>

          <.form
            for={Map.fetch!(@agent_list_forms, agent.id)}
            id={"agent-list-form-#{agent.id}"}
            phx-change="set_contact_list"
            phx-value-agent-id={agent.id}
            class="mt-2 flex items-baseline gap-2 text-[11px] text-faint"
          >
            File matches in
            <.input
              field={Map.fetch!(@agent_list_forms, agent.id)[:contact_list_id]}
              type="select"
              options={Enum.map(@contact_lists, &{&1.name, &1.id})}
              class="select w-auto py-0 text-[11px]"
            />
          </.form>

          <p :if={agent.last_error} class="mt-1 text-[12px] text-destructive">{agent.last_error}</p>
        </div>

        <div class="flex shrink-0 items-center gap-5 text-xs">
          <button
            phx-click="run"
            phx-value-id={agent.id}
            disabled={MapSet.member?(@running, agent.id) or !@api_configured}
            class="act-key"
          >
            {if MapSet.member?(@running, agent.id), do: "Running…", else: "Run now"}
          </button>
          <button phx-click="toggle" phx-value-id={agent.id} class="act">
            {if agent.enabled, do: "Pause", else: "Resume"}
          </button>
          <button
            phx-click="delete"
            phx-value-id={agent.id}
            data-confirm="Remove this agent? Leads it already found are kept."
            class="act-danger"
          >
            Remove
          </button>
        </div>
      </article>
    </div>

    <section class="mt-10 border-t border-border pt-6">
      <p class="nb-eyebrow mb-4">New agent</p>

      <.form for={@agent_form} id="signal-agent-form" phx-submit="create" class="flex flex-col gap-5">
        <div class="grid grid-cols-1 gap-5 sm:grid-cols-[12rem_minmax(0,1fr)]">
          <.input
            field={@agent_form[:kind]}
            type="select"
            label="Watch"
            options={[
              {"Posts matching a search", "keyword"},
              {"Followers of an account", "follower"},
              {"People replying to an account", "profile"},
              {"People posting in a list", "list"}
            ]}
            class="select"
          />

          <.input
            field={@agent_form[:target]}
            type="text"
            label="Target"
            placeholder="a search query, @handle, or list id"
            class="input"
            required
          />
        </div>

        <div>
          <label class="label" for={@agent_form[:ideal_customer].id}>
            Who counts as a good match
          </label>
          <p class="mb-2 text-[12px] text-faint">
            Plain language. This is the whole configuration — the model reads it and judges
            each person against it.
          </p>
          <.input
            field={@agent_form[:ideal_customer]}
            type="textarea"
            rows="3"
            class="textarea"
            placeholder="Founders or engineers at small software companies who are frustrated with their current scheduling tool. Not agencies, not people selling growth services."
          />
        </div>

        <div class="flex flex-wrap items-end gap-5">
          <.input
            field={@agent_form[:min_score]}
            type="select"
            label="Minimum score"
            options={[40, 50, 60, 70, 80]}
            class="select w-auto pr-6"
          />
          <.input
            field={@agent_form[:contact_list_id]}
            type="select"
            label="File matches in"
            options={Enum.map(@contact_lists, &{&1.name, &1.id})}
            class="select w-auto pr-6"
          />
          <button type="submit" class="act-key pb-2 text-xs">Create agent</button>
        </div>
      </.form>
    </section>
    """
  end

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp start_run(socket, agent) do
    agent = SuperX.Repo.preload(agent, :x_account)
    parent = self()

    Task.Supervisor.start_child(SuperX.TaskSupervisor, fn ->
      send(parent, {:ran, agent.id, SignalSweep.run_agent(agent)})
    end)

    update(socket, :running, &MapSet.put(&1, agent.id))
  end

  defp new_agent_form do
    to_form(
      %{
        "kind" => "keyword",
        "target" => "",
        "ideal_customer" => "",
        "min_score" => "60",
        "contact_list_id" => ""
      },
      as: :agent
    )
  end
end
