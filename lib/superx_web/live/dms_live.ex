defmodule SuperXWeb.DMsLive do
  @moduledoc """
  The private inbox: one-to-one conversations, their chronological thread,
  and replies sent with the connected account's OAuth grant.

  The screen remains useful as a truthful capability surface while inbound
  sync is unavailable: it explains the operator and provider requirements
  instead of presenting an empty inbox as though polling had succeeded.
  """

  use SuperXWeb, :live_view

  alias SuperX.DMs
  alias SuperX.Engage.Replier

  @impl true
  def mount(_params, _session, socket) do
    account = socket.assigns.current_x_account

    {:ok,
     socket
     |> assign(page_title: "DMs")
     |> assign(:availability, DMs.availability(account))
     |> assign(:ai_configured, SuperX.AI.configured?())
     |> assign(:conversation, nil)
     |> assign(:conversations_empty?, true)
     |> assign(:drafting, false)
     |> assign(:reply_form, reply_form())
     |> stream(:conversations, [])
     |> stream(:messages, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, params["conversation"])}
  end

  defp load(socket, requested_id) do
    account = socket.assigns.current_x_account
    conversations = DMs.list_conversations(account)
    conversation = select_conversation(account, conversations, requested_id)
    messages = if conversation, do: conversation.messages, else: []

    socket
    |> assign(:conversation, conversation)
    |> assign(:conversations_empty?, conversations == [])
    |> assign(:reply_form, reply_form())
    |> stream(:conversations, conversations, reset: true)
    |> stream(:messages, messages, reset: true)
  end

  defp select_conversation(_account, [], _requested_id), do: nil

  defp select_conversation(account, conversations, requested_id) do
    requested = requested_id && DMs.get_conversation(account, requested_id)
    requested || conversations |> List.first() |> then(&DMs.get_conversation(account, &1.id))
  end

  # --- Replying ------------------------------------------------------------

  @impl true
  def handle_event("change_reply", %{"reply" => params}, socket) do
    {:noreply, assign(socket, :reply_form, to_form(params, as: :reply))}
  end

  def handle_event("send_reply", %{"reply" => %{"text" => text}}, socket) do
    account = socket.assigns.current_x_account
    conversation = socket.assigns.conversation

    case conversation && DMs.send_reply(account, conversation.id, text) do
      {:ok, _message} ->
        {:noreply,
         socket
         |> put_flash(:info, "Message sent.")
         |> load(conversation.id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, send_error(reason))}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("draft_reply", _params, %{assigns: %{conversation: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("draft_reply", _params, socket) do
    if draft_available?(socket) do
      start_draft(socket)
    else
      {:noreply, socket}
    end
  end

  defp start_draft(socket) do
    user = socket.assigns.current_user
    account = socket.assigns.current_x_account
    conversation = socket.assigns.conversation
    parent = self()

    Task.Supervisor.start_child(SuperX.TaskSupervisor, fn ->
      result =
        Replier.draft_direct_message(
          user,
          account,
          conversation.participant_handle,
          conversation.messages
        )

      send(parent, {:dm_drafted, conversation.id, result})
    end)

    {:noreply, assign(socket, :drafting, true)}
  end

  @impl true
  def handle_info({:dm_drafted, conversation_id, result}, socket) do
    socket = assign(socket, :drafting, false)

    if socket.assigns.conversation && socket.assigns.conversation.id == conversation_id do
      apply_draft_result(socket, result)
    else
      {:noreply, socket}
    end
  end

  defp apply_draft_result(socket, {:ok, text}) do
    {:noreply, assign(socket, :reply_form, reply_form(text))}
  end

  defp apply_draft_result(socket, {:error, :quota_exceeded, details}) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "You've used all #{details.limit} assisted replies for today."
     )}
  end

  defp apply_draft_result(socket, {:error, reason}) do
    require Logger
    Logger.warning("DM drafting failed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Couldn't write that reply. Try again in a moment.")}
  end

  # --- Render --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header
      title="DMs"
      description="Private conversations, kept with the account that received them. Draft in your voice, then send through your own X connection."
    />

    <.availability_notice availability={@availability} account={@current_x_account} />

    <section
      :if={@conversations_empty?}
      id="dms-empty-state"
      class="border-y border-border py-16 text-center"
    >
      <p class="text-muted-foreground">No conversations are stored yet.</p>
      <p class="mx-auto mt-2 max-w-[58ch] text-[12px] text-faint">
        {empty_detail(@availability)}
      </p>
    </section>

    <div
      :if={!@conversations_empty?}
      id="dms-inbox"
      class="grid min-h-[34rem] grid-cols-1 border-y border-border lg:grid-cols-[18rem_minmax(0,1fr)]"
    >
      <aside class="border-b border-border lg:border-b-0 lg:border-r">
        <p class="nb-eyebrow px-3 py-3">Conversations</p>

        <div id="dm-conversations" phx-update="stream" class="flex flex-col">
          <.link
            :for={{id, conversation} <- @streams.conversations}
            id={id}
            patch={~p"/dms?conversation=#{conversation.id}"}
            aria-current={@conversation && @conversation.id == conversation.id && "page"}
            class={[
              "group grid grid-cols-[2rem_minmax(0,1fr)] gap-3 border-t border-border px-3 py-3 transition-colors hover:bg-accent",
              @conversation && @conversation.id == conversation.id && "bg-accent"
            ]}
          >
            <Layouts.avatar src={conversation.participant_avatar_url} size="size-8" />
            <span class="min-w-0">
              <span class="flex items-baseline gap-2">
                <span class="truncate font-medium">
                  {conversation.participant_name || conversation.participant_handle ||
                    "Unknown account"}
                </span>
                <span class="nb-mono ml-auto shrink-0 text-[10px] text-faint">
                  {ago(conversation.last_message_at)}
                </span>
              </span>
              <span
                :if={conversation.participant_handle}
                class="block truncate text-[11px] text-faint"
              >
                @{conversation.participant_handle}
              </span>
              <span class="mt-1 block truncate text-[12px] text-muted-foreground">
                {conversation.last_message_text || "No messages stored."}
              </span>
            </span>
          </.link>
        </div>
      </aside>

      <section :if={@conversation} id="dm-thread" class="flex min-w-0 flex-col">
        <header class="flex items-center gap-3 border-b border-border px-5 py-3">
          <Layouts.avatar src={@conversation.participant_avatar_url} size="size-8" />
          <div class="min-w-0">
            <h2 class="truncate text-[15px]">
              {@conversation.participant_name || @conversation.participant_handle || "Unknown account"}
            </h2>
            <p :if={@conversation.participant_handle} class="text-[11px] text-faint">
              @{@conversation.participant_handle}
            </p>
          </div>
        </header>

        <div id="dm-messages" phx-update="stream" class="flex-1 px-5">
          <div
            id="dm-messages-empty"
            class="hidden only:block py-16 text-center text-muted-foreground"
          >
            This conversation has no stored messages yet.
          </div>
          <article
            :for={{id, message} <- @streams.messages}
            id={id}
            class={[
              "border-b border-border py-4",
              message.direction == "outbound" && "pl-8 sm:pl-16",
              message.direction == "inbound" && "pr-8 sm:pr-16"
            ]}
          >
            <p class="nb-eyebrow mb-1.5 text-[10px]">
              {message_author(message, @conversation, @current_x_account)}
              <span class="nb-mono ml-2 normal-case tracking-normal text-faint">
                {ago(message.sent_at)}
              </span>
            </p>
            <p class="post-body">{message.text}</p>
          </article>
        </div>

        <div class="border-t border-border px-5 py-4">
          <.form
            for={@reply_form}
            id="dm-reply-form"
            phx-change="change_reply"
            phx-submit="send_reply"
          >
            <.input
              field={@reply_form[:text]}
              type="textarea"
              label="Your reply"
              rows="4"
              placeholder="Write a private reply"
              disabled={@availability != :ready}
            />

            <div class="mt-2 flex flex-wrap items-center gap-5 text-xs">
              <button
                type="submit"
                id="dm-send-reply"
                class="act-key"
                disabled={@availability != :ready or blank_reply?(@reply_form)}
                phx-disable-with="Sending…"
              >
                Send message
              </button>
              <button
                :if={@availability == :ready and @ai_configured and reply_needed?(@conversation)}
                type="button"
                id="dm-draft-reply"
                phx-click="draft_reply"
                class="act"
                disabled={@drafting}
              >
                {if @drafting, do: "Writing…", else: "Draft in my voice"}
              </button>
              <span class="nb-mono ml-auto text-[11px] text-faint">
                {reply_length(@reply_form)} characters
              </span>
            </div>
          </.form>
        </div>
      </section>
    </div>
    """
  end

  attr :availability, :atom, required: true
  attr :account, :map, required: true

  defp availability_notice(%{availability: :disabled} = assigns) do
    ~H"""
    <section id="dm-availability" class="mb-8 border-y border-border py-4">
      <p class="font-medium">DM access is off on this installation.</p>
      <p class="mt-1 max-w-[64ch] text-[12px] text-muted-foreground">
        Upgrade the X app to Read and write and Direct message, then set <code class="nb-mono text-[11px] text-foreground">SUPERX_ENABLE_DMS=true</code>.
        Existing accounts must reconnect after the change.
      </p>
    </section>
    """
  end

  defp availability_notice(%{availability: :reauthorize} = assigns) do
    ~H"""
    <section id="dm-availability" class="mb-8 border-y border-border py-4">
      <p class="font-medium">@{@account.handle} has not granted DM access.</p>
      <p class="mt-1 text-[12px] text-muted-foreground">
        The permission change invalidates the old grant.
        <.link href={~p"/auth/x?redirect_to=/dms"} class="act-key ml-1">Reconnect the account</.link>
        to continue.
      </p>
    </section>
    """
  end

  defp availability_notice(assigns) do
    ~H"""
    <section id="dm-sync-status" class="mb-8 border-y border-border py-4">
      <p class="font-medium">Incoming sync is waiting on the read provider.</p>
      <p class="mt-1 max-w-[68ch] text-[12px] text-muted-foreground">
        twitterapi.io has no API-key endpoint that can enumerate this OAuth account's inbox.
        Stored conversations can be answered, but new inbound messages will not appear yet.
      </p>
    </section>
    """
  end

  defp reply_form(text \\ ""), do: to_form(%{"text" => text}, as: :reply)

  defp reply_text(form), do: Phoenix.HTML.Form.input_value(form, :text) || ""
  defp reply_length(form), do: form |> reply_text() |> String.length()
  defp blank_reply?(form), do: form |> reply_text() |> String.trim() == ""

  defp draft_available?(socket) do
    socket.assigns.availability == :ready and socket.assigns.ai_configured and
      reply_needed?(socket.assigns.conversation) and not socket.assigns.drafting
  end

  defp reply_needed?(conversation) do
    match?(%{direction: "inbound"}, List.last(conversation.messages))
  end

  defp message_author(%{direction: "outbound"}, _conversation, account),
    do: account.display_name || "@#{account.handle}"

  defp message_author(_message, conversation, _account),
    do: conversation.participant_name || "@#{conversation.participant_handle}"

  defp empty_detail(:disabled) do
    "The feature flag is off, so OAuth still requests the existing non-DM scopes."
  end

  defp empty_detail(:reauthorize) do
    "Reconnect this account before sending. Incoming sync also needs a compatible provider endpoint."
  end

  defp empty_detail(:ready) do
    "Incoming sync cannot start until twitterapi.io offers an API-key inbox endpoint."
  end

  defp send_error(:disabled), do: "DM access is disabled on this installation."
  defp send_error(:reauthorize), do: "Reconnect this X account to grant DM access."
  defp send_error(:empty_message), do: "Write a message before sending."
  defp send_error(:not_found), do: "That conversation is not available for this account."
  defp send_error(:reauth_required), do: "Your X connection expired. Reconnect the account."
  defp send_error({:rate_limited, _}), do: "X is rate limiting DMs. Try again later."

  defp send_error({:http_error, 403, _}) do
    "X refused that DM. The recipient may not accept messages from this account."
  end

  defp send_error({:store_failed, _}) do
    "X accepted the message, but SuperX could not record it. Check X before trying again."
  end

  defp send_error(_reason), do: "We couldn't send that message."
end
