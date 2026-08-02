defmodule SuperXWeb.ContactsLive do
  @moduledoc """
  The people agents found, organised into stored audiences and one live
  outreach view without duplicating CRM state into memberships.
  """

  use SuperXWeb, :live_view

  alias SuperX.Signals
  alias SuperX.Signals.{ContactList, Lead}

  @statuses ~w(new contacted replied won archived)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Contacts")
     |> assign(:ai_configured, SuperX.AI.configured?())
     |> assign(:status, nil)
     |> assign(:statuses, @statuses)
     |> assign(:selected_list, nil)
     |> assign(:editing, nil)
     |> assign(:new_list?, false)
     |> assign(:list_form, to_form(%{"name" => ""}, as: :list))
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in @statuses, do: params["status"]
    list = Signals.get_contact_list(socket.assigns.current_x_account, params["list"])

    {:noreply,
     socket
     |> assign(:status, status)
     |> assign(:selected_list, list)
     |> load()}
  end

  defp load(socket) do
    account = socket.assigns.current_x_account
    list = socket.assigns.selected_list
    leads = Signals.list_leads(account, status: socket.assigns.status, list: list)
    lists = Signals.list_contact_lists(account)
    share = list && Signals.get_contact_list_share(account, list)

    socket
    |> assign(:lists, lists)
    |> assign(:editable_lists, Enum.filter(lists, &ContactList.editable?/1))
    |> assign(:list_counts, Signals.contact_list_counts(account))
    |> assign(:counts, Signals.lead_counts(account, list: list))
    |> assign(:memberships, Signals.contact_list_ids_for_leads(account, Enum.map(leads, & &1.id)))
    |> assign(:share, share)
    |> assign(:share_url, share && SuperXWeb.Endpoint.url() <> ~p"/circle/#{share.token}")
    |> stream(:leads, leads, reset: true)
  end

  @impl true
  def handle_event("set_status", %{"id" => id, "status" => status}, socket) do
    with true <- status in @statuses,
         %Lead{} = lead <- Signals.get_lead(socket.assigns.current_x_account, id),
         {:ok, _lead} <- Signals.set_lead_status(lead, status) do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, socket}
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
        {:ok, _lead} = Signals.update_lead(lead, %{notes: notes})
        {:noreply, socket |> assign(:editing, nil) |> load()}
    end
  end

  def handle_event("cancel_notes", _params, socket), do: {:noreply, assign(socket, :editing, nil)}

  def handle_event("show_new_list", _params, socket) do
    {:noreply, assign(socket, :new_list?, true)}
  end

  def handle_event("cancel_new_list", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_list?, false)
     |> assign(:list_form, to_form(%{"name" => ""}, as: :list))}
  end

  def handle_event("create_list", %{"list" => attrs}, socket) do
    case Signals.create_contact_list(socket.assigns.current_x_account, attrs) do
      {:ok, list} ->
        {:noreply,
         socket
         |> assign(:new_list?, false)
         |> assign(:list_form, to_form(%{"name" => ""}, as: :list))
         |> put_flash(:info, "List created.")
         |> push_patch(to: contacts_path(list.id, socket.assigns.status))}

      {:error, changeset} ->
        {:noreply, assign(socket, :list_form, to_form(changeset, as: :list))}
    end
  end

  def handle_event("delete_list", _params, %{assigns: %{selected_list: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("delete_list", _params, socket) do
    case Signals.delete_contact_list(
           socket.assigns.current_x_account,
           socket.assigns.selected_list.id
         ) do
      {:ok, _list} ->
        {:noreply,
         socket
         |> put_flash(:info, "List removed. Contacts were kept.")
         |> push_patch(to: contacts_path(nil, socket.assigns.status))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That built-in list cannot be removed.")}
    end
  end

  def handle_event(
        "toggle_list_membership",
        %{"lead-id" => lead_id, "list-id" => list_id},
        socket
      ) do
    case Signals.toggle_contact_list_membership(
           socket.assigns.current_x_account,
           lead_id,
           list_id
         ) do
      {:ok, _change} -> {:noreply, load(socket)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("create_share", _params, %{assigns: %{selected_list: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "Choose a list to share first.")}
  end

  def handle_event("create_share", _params, socket) do
    case Signals.create_contact_list_share(
           socket.assigns.current_x_account,
           socket.assigns.selected_list
         ) do
      {:ok, _share} ->
        {:noreply, socket |> put_flash(:info, "Public circle ready.") |> load()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't create that public circle.")}
    end
  end

  def handle_event("revoke_share", _params, socket) do
    :ok =
      Signals.revoke_contact_list_share(
        socket.assigns.current_x_account,
        socket.assigns.selected_list
      )

    {:noreply, socket |> put_flash(:info, "Public circle turned off.") |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header
      title="Contacts"
      description="People your agents found, ordered by how well they matched. Scores are a starting point, not a verdict."
    >
      <:action>
        <div class="flex flex-wrap justify-end gap-x-5 gap-y-2 text-xs">
          <.link href={export_path(@selected_list)} class="act whitespace-nowrap">Export CSV</.link>
          <button phx-click="create_share" class="act whitespace-nowrap">
            {if @share, do: "Replace shared link", else: "Share your circle"}
          </button>
          <.link navigate={~p"/signals"} class="act-key whitespace-nowrap">Manage agents</.link>
        </div>
      </:action>
    </Layouts.page_header>

    <p
      :if={!@ai_configured}
      id="contacts-unscored-notice"
      class="mb-8 max-w-[64ch] text-[13px] text-muted-foreground"
    >
      No LLM is configured. New contacts are kept with the agent's minimum score as a
      placeholder and are explicitly marked as not AI-scored.
    </p>

    <section id="contact-lists" class="mb-7 border-y border-border py-4">
      <div class="flex flex-wrap items-center gap-x-6 gap-y-3">
        <.link
          patch={contacts_path(nil, @status)}
          class={if is_nil(@selected_list), do: "act-key", else: "act"}
          aria-current={is_nil(@selected_list) && "page"}
        >
          All
        </.link>
        <.link
          :for={list <- @lists}
          id={"contact-list-#{list.id}"}
          patch={contacts_path(list.id, @status)}
          class={if @selected_list && @selected_list.id == list.id, do: "act-key", else: "act"}
          aria-current={@selected_list && @selected_list.id == list.id && "page"}
        >
          {list.name}
          <span :if={ContactList.derived?(list)} class="nb-mono ml-1 text-[9px] uppercase text-faint">
            auto
          </span>
          <span class="nb-mono ml-1 text-[11px] text-faint">
            {Map.get(@list_counts, list.id, 0)}
          </span>
        </.link>
        <button phx-click="show_new_list" class="act text-xs">New list</button>
      </div>

      <.form
        :if={@new_list?}
        for={@list_form}
        id="contact-list-form"
        phx-submit="create_list"
        class="mt-4 flex max-w-md items-end gap-5 border-t border-border pt-4"
      >
        <.input
          field={@list_form[:name]}
          type="text"
          label="List name"
          placeholder="Partners"
          class="input"
          required
        />
        <div class="flex shrink-0 gap-4 pb-2 text-xs">
          <button type="submit" class="act-key">Create</button>
          <button type="button" phx-click="cancel_new_list" class="act">Cancel</button>
        </div>
      </.form>

      <div
        :if={@selected_list}
        id="selected-list-note"
        class="mt-3 flex flex-wrap items-baseline justify-between gap-3 border-t border-border pt-3"
      >
        <p class="text-[12px] text-faint">
          <%= if ContactList.derived?(@selected_list) do %>
            Updates automatically as contacts move into Contacted or Replied.
          <% else %>
            Add or remove people from this list through each contact's Lists menu.
          <% end %>
        </p>
        <button
          :if={ContactList.deletable?(@selected_list)}
          phx-click="delete_list"
          data-confirm="Remove this list? Its contacts will be kept."
          class="act-danger text-xs"
        >
          Remove list
        </button>
      </div>
    </section>

    <section :if={@share} id="contact-list-share" class="mb-8 border-y border-border py-4">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-baseline sm:justify-between">
        <div class="min-w-0">
          <p class="nb-eyebrow">Public circle</p>
          <a
            href={@share_url}
            target="_blank"
            rel="noopener"
            class="act mt-1 block truncate text-xs"
          >
            {@share_url}
          </a>
          <p class="mt-1 text-[11px] text-faint">
            Shares names, handles, bios and public follower figures. Notes and qualification stay private.
          </p>
        </div>
        <button phx-click="revoke_share" class="act-danger shrink-0 text-xs">Turn off</button>
      </div>
    </section>

    <div class="mb-6 flex flex-wrap gap-6 border-b border-border">
      <.link
        patch={contacts_path(@selected_list && @selected_list.id, nil)}
        class="tab"
        aria-selected={to_string(is_nil(@status))}
      >
        All <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, "all", 0)}</span>
      </.link>
      <.link
        :for={status <- @statuses}
        patch={contacts_path(@selected_list && @selected_list.id, status)}
        class="tab"
        aria-selected={to_string(@status == status)}
      >
        {String.capitalize(status)}
        <span class="nb-mono ml-1 text-[11px] text-faint">{Map.get(@counts, status, 0)}</span>
      </.link>
    </div>

    <div id="contacts" phx-update="stream" class="flex flex-col">
      <div id="contacts-empty" class="hidden only:block py-16 text-center">
        <p class="text-muted-foreground">{empty_message(@selected_list, @status)}</p>
        <.link
          :if={@selected_list && !ContactList.derived?(@selected_list)}
          patch={contacts_path(nil, @status)}
          class="act-key mt-2 inline-block text-xs"
        >
          Browse all contacts
        </.link>
        <.link
          :if={is_nil(@selected_list) && is_nil(@status)}
          navigate={~p"/signals"}
          class="act-key mt-2 inline-block text-xs"
        >
          Set up an agent
        </.link>
      </div>

      <article
        :for={{id, lead} <- @streams.leads}
        id={id}
        class="grid grid-cols-1 gap-6 border-b border-border py-5 first:border-t sm:grid-cols-[minmax(0,1fr)_auto]"
      >
        <div class="min-w-0">
          <div class="flex items-start gap-3">
            <Layouts.avatar
              src={lead.avatar_url}
              name={lead.display_name || lead.handle}
              size="size-8"
            />

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
                <span :if={lead.score} class="score" data-tier={score_tier(lead.score)}>
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
                <form id={"contact-notes-#{lead.id}"} phx-submit="save_notes">
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
          <div class="flex items-center gap-5">
            <details id={"contact-lists-#{lead.id}"} class="relative">
              <summary class="act list-none cursor-pointer">Lists</summary>
              <div class="absolute right-0 z-10 mt-2 min-w-44 border-y border-border bg-popover py-2">
                <button
                  :for={list <- @editable_lists}
                  type="button"
                  phx-click="toggle_list_membership"
                  phx-value-lead-id={lead.id}
                  phx-value-list-id={list.id}
                  class="act flex w-full items-center gap-2 px-3 py-1.5 text-left"
                >
                  <.icon
                    name={
                      if member?(@memberships, lead.id, list.id), do: "hero-check", else: "hero-plus"
                    }
                    class="size-3.5"
                  />
                  {list.name}
                </button>
              </div>
            </details>
            <button
              :if={@editing != lead.id}
              phx-click="edit_notes"
              phx-value-id={lead.id}
              class="act"
            >
              {if lead.notes, do: "Edit note", else: "Add note"}
            </button>
          </div>
        </div>
      </article>
    </div>
    """
  end

  defp contacts_path(nil, nil), do: ~p"/contacts"
  defp contacts_path(nil, status), do: ~p"/contacts?status=#{status}"
  defp contacts_path(list_id, nil), do: ~p"/contacts?list=#{list_id}"
  defp contacts_path(list_id, status), do: ~p"/contacts?list=#{list_id}&status=#{status}"

  defp export_path(nil), do: ~p"/contacts/export"
  defp export_path(list), do: ~p"/contacts/export?list=#{list.id}"

  defp member?(memberships, lead_id, list_id) do
    memberships |> Map.get(lead_id, MapSet.new()) |> MapSet.member?(list_id)
  end

  defp empty_message(%ContactList{kind: "engage"}, _status) do
    "Nobody is in active outreach. Contacts appear here when marked Contacted or Replied."
  end

  defp empty_message(%ContactList{name: name}, nil), do: "No contacts in #{name}."

  defp empty_message(%ContactList{name: name}, status) do
    "No #{status} contacts in #{name}."
  end

  defp empty_message(nil, nil), do: "Nothing here yet."
  defp empty_message(nil, status), do: "No contacts are marked #{status}."

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

  # Same three-step ramp as Engage priority, so a number means one thing.
  defp score_tier(score) when score >= 80, do: "strong"
  defp score_tier(score) when score >= 60, do: "mid"
  defp score_tier(_score), do: "weak"
end
