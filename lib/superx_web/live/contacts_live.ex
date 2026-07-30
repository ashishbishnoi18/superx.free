defmodule SuperXWeb.ContactsLive do
  @moduledoc """
  The people the agents found — a light CRM, ordered by fit.
  """

  use SuperXWeb, :live_view

  alias SuperX.Signals
  alias SuperX.Signals.Lead

  @statuses ~w(new contacted replied won archived)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Contacts")
     |> assign(:status, nil)
     |> assign(:statuses, @statuses)
     |> assign(:editing, nil)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in @statuses, do: params["status"]
    {:noreply, socket |> assign(:status, status) |> load()}
  end

  defp load(socket) do
    account = socket.assigns.current_x_account

    socket
    |> assign(:leads, Signals.list_leads(account, status: socket.assigns.status))
    |> assign(:counts, Signals.lead_counts(account))
  end

  @impl true
  def handle_event("set_status", %{"id" => id, "status" => status}, socket) do
    case Signals.get_lead(socket.assigns.current_x_account, id) do
      nil -> {:noreply, socket}
      lead -> {:ok, _} = Signals.set_lead_status(lead, status); {:noreply, load(socket)}
    end
  end

  def handle_event("edit_notes", %{"id" => id}, socket) do
    {:noreply, assign(socket, :editing, id)}
  end

  def handle_event("save_notes", %{"lead_id" => id, "notes" => notes}, socket) do
    case Signals.get_lead(socket.assigns.current_x_account, id) do
      nil ->
        {:noreply, socket}

      lead ->
        {:ok, _} = Signals.update_lead(lead, %{notes: notes})
        {:noreply, socket |> assign(:editing, nil) |> load()}
    end
  end

  def handle_event("cancel_notes", _params, socket), do: {:noreply, assign(socket, :editing, nil)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header
      title="Contacts"
      description="People your agents found, ordered by how well they matched. Scores are a starting point, not a verdict."
    >
      <:action>
        <.link navigate={~p"/signals"} class="act whitespace-nowrap text-xs">Manage agents</.link>
      </:action>
    </Layouts.page_header>

    <div class="mb-6 flex flex-wrap gap-6 border-b border-border">
      <.link patch={~p"/contacts"} class="tab" aria-selected={is_nil(@status)}>
        All <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, "all", 0)}</span>
      </.link>
      <.link
        :for={status <- @statuses}
        patch={~p"/contacts?status=#{status}"}
        class="tab"
        aria-selected={@status == status}
      >
        {String.capitalize(status)}
        <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, status, 0)}</span>
      </.link>
    </div>

    <div :if={@leads == []} class="py-16 text-center">
      <p class="text-muted-foreground">
        Nothing here yet.
        <.link navigate={~p"/signals"} class="act-key">Set up an agent</.link>
        and it fills in as matches are found.
      </p>
    </div>

    <div class="flex flex-col">
      <article
        :for={lead <- @leads}
        class="grid grid-cols-1 gap-6 border-b border-border py-5 first:border-t sm:grid-cols-[minmax(0,1fr)_auto]"
      >
        <div class="min-w-0">
          <div class="flex items-start gap-3">
            <Layouts.avatar src={lead.avatar_url} size="size-8" />

            <div class="min-w-0 flex-1">
              <p class="flex flex-wrap items-baseline gap-2">
                <a
                  href={Lead.url(lead)}
                  target="_blank"
                  rel="noopener"
                  class="hover-ember font-medium"
                >
                  {lead.display_name || lead.handle}
                </a>
                <span class="text-faint">@{lead.handle}</span>
                <span :if={lead.score} class={["nb-mono text-[11px]", score_class(lead.score)]}>
                  {lead.score}
                </span>
              </p>

              <p class="nb-mono mt-0.5 text-[11px] text-faint">
                {compact(lead.followers_count)} followers
                <span :if={lead.location}>· {lead.location}</span>
                <span :if={lead.signal_agent}>· via {lead.signal_agent.name}</span>
              </p>

              <p :if={lead.bio} class="mt-1.5 max-w-[62ch] text-[13px] text-muted-foreground">
                {lead.bio}
              </p>

              <p :if={lead.reason} class="mt-1.5 max-w-[62ch] text-[13px]">
                {lead.reason}
              </p>

              <a
                :if={Lead.source_url(lead)}
                href={Lead.source_url(lead)}
                target="_blank"
                rel="noopener"
                class="act mt-1.5 block max-w-[62ch] text-[13px] italic"
              >
                “{String.slice(lead.source_post_text || "", 0, 140)}”
              </a>

              <div :if={@editing == lead.id} class="mt-3 max-w-[62ch]">
                <form phx-submit="save_notes">
                  <%!-- Named lead_id rather than id: `name="id"` on an input
                        shadows the form element's own id. --%>
                  <input type="hidden" name="lead_id" value={lead.id} />
                  <textarea name="notes" rows="3" class="textarea" autofocus>{lead.notes}</textarea>
                  <div class="mt-2 flex gap-5 text-xs">
                    <button type="submit" class="act-key">Save</button>
                    <button type="button" phx-click="cancel_notes" class="act">Cancel</button>
                  </div>
                </form>
              </div>

              <p
                :if={@editing != lead.id and lead.notes}
                class="mt-2 max-w-[62ch] whitespace-pre-wrap border-l border-border pl-3 text-[13px] text-muted-foreground"
              >
                {lead.notes}
              </p>
            </div>
          </div>
        </div>

        <div class="flex shrink-0 flex-col items-start gap-2 text-xs sm:items-end">
          <div class="flex flex-wrap gap-4">
            <button
              :for={next <- next_statuses(lead.status)}
              phx-click="set_status"
              phx-value-id={lead.id}
              phx-value-status={next}
              class={if next == "archived", do: "act-danger", else: "act-key"}
            >
              {status_label(next)}
            </button>
          </div>
          <button :if={@editing != lead.id} phx-click="edit_notes" phx-value-id={lead.id} class="act">
            {if lead.notes, do: "Edit note", else: "Add note"}
          </button>
        </div>
      </article>
    </div>
    """
  end

  # Only the moves that make sense from here, so the row isn't a wall of
  # every possible state.
  defp next_statuses("new"), do: ["contacted", "archived"]
  defp next_statuses("contacted"), do: ["replied", "archived"]
  defp next_statuses("replied"), do: ["won", "archived"]
  defp next_statuses("won"), do: ["archived"]
  defp next_statuses("archived"), do: ["new"]

  defp status_label("contacted"), do: "Mark contacted"
  defp status_label("replied"), do: "They replied"
  defp status_label("won"), do: "Won"
  defp status_label("archived"), do: "Archive"
  defp status_label("new"), do: "Restore"

  defp score_class(s) when s >= 80, do: "text-primary"
  defp score_class(s) when s >= 60, do: "text-muted-foreground"
  defp score_class(_), do: "text-faint"
end
