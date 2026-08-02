defmodule SuperXWeb.AskLive do
  @moduledoc """
  Chat with tools over the account.
  """

  use SuperXWeb, :live_view

  alias SuperX.Ask

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Ask")
     |> assign(:chat, nil)
     |> assign(:messages, [])
     |> assign(:thinking, false)
     |> assign(:draft, "")
     |> assign(:ai_configured, SuperX.AI.configured?())
     |> assign(
       :chats,
       Ask.list_chats(socket.assigns.current_user, socket.assigns.current_x_account)
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Ask.get_chat(socket.assigns.current_user, socket.assigns.current_x_account, id) do
      nil ->
        {:noreply, push_patch(socket, to: ~p"/ask")}

      chat ->
        {:noreply, socket |> assign(:chat, chat) |> assign(:messages, chat.messages)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(:chat, nil) |> assign(:messages, [])}
  end

  @impl true
  def handle_event("ask", %{"question" => question}, socket) do
    question = String.trim(question)

    if question == "" do
      {:noreply, socket}
    else
      user = socket.assigns.current_user
      account = socket.assigns.current_x_account

      {:ok, chat} =
        case socket.assigns.chat do
          nil -> Ask.create_chat(user, account, Ask.title_from(question))
          chat -> {:ok, chat}
        end

      # Show the question immediately rather than after the round trip —
      # a turn can take ten seconds with tools.
      pending = %SuperX.Ask.Message{
        role: "user",
        content: question,
        inserted_at: DateTime.utc_now()
      }

      parent = self()

      Task.Supervisor.start_child(SuperX.TaskSupervisor, fn ->
        send(parent, {:answered, chat.id, Ask.ask(user, account, chat, question)})
      end)

      {:noreply,
       socket
       |> assign(:chat, chat)
       |> assign(:messages, socket.assigns.messages ++ [pending])
       |> assign(:thinking, true)
       |> assign(:draft, "")}
    end
  end

  def handle_event("new_chat", _params, socket) do
    {:noreply, socket |> assign(:chat, nil) |> assign(:messages, []) |> push_patch(to: ~p"/ask")}
  end

  def handle_event("delete_chat", %{"id" => id}, socket) do
    Ask.delete_chat(socket.assigns.current_user, socket.assigns.current_x_account, id)

    {:noreply,
     socket
     |> assign(
       :chats,
       Ask.list_chats(socket.assigns.current_user, socket.assigns.current_x_account)
     )
     |> assign(:chat, nil)
     |> assign(:messages, [])
     |> push_patch(to: ~p"/ask")}
  end

  def handle_event("suggest", %{"q" => q}, socket) do
    {:noreply, assign(socket, :draft, q)}
  end

  @impl true
  def handle_info({:answered, chat_id, result}, socket) do
    socket = assign(socket, :thinking, false)
    send(self(), :refresh_quota)

    case result do
      {:ok, _message} ->
        chat =
          Ask.get_chat(
            socket.assigns.current_user,
            socket.assigns.current_x_account,
            chat_id
          )

        {:noreply,
         socket
         |> assign(:chat, chat)
         |> assign(:messages, chat.messages)
         |> assign(
           :chats,
           Ask.list_chats(socket.assigns.current_user, socket.assigns.current_x_account)
         )}

      {:error, :quota_exceeded, _details} ->
        {:noreply, put_flash(socket, :error, "You're out of AI credits for this window.")}

      {:error, reason} ->
        require Logger
        Logger.warning("Ask failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "That didn't go through. Try again in a moment.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-6">
      <div>
        <h1 class="text-[1.75rem] font-semibold leading-[1.15] tracking-[-0.03em]">Ask</h1>
        <p class="mt-2 max-w-[56ch] text-muted-foreground">
          It can read your analytics, queue, shelf, Articles, topic feeds, inbox, contacts,
          and the library, and draft or queue posts. It can't publish — that stays with you.
        </p>
      </div>
      <button :if={@chat} phx-click="new_chat" class="act-key shrink-0 text-xs">New chat</button>
    </div>

    <p :if={!@ai_configured} class="mt-8 max-w-[60ch] text-muted-foreground">
      Set <code class="nb-mono text-[12px] text-foreground">ANTHROPIC_API_KEY</code> to use this.
    </p>

    <div :if={@ai_configured} class="mt-8">
      <div :if={@messages == []} class="flex flex-col gap-3 pb-8">
        <p class="nb-eyebrow">Try</p>
        <button
          :for={
            q <- [
              "How is my account doing this month?",
              "What should I post about today?",
              "Which article drafts am I still working on?",
              "Who's worth replying to right now?",
              "Draft something about what I learned shipping this week"
            ]
          }
          phx-click="suggest"
          phx-value-q={q}
          class="act text-left"
        >
          {q}
        </button>
      </div>

      <div class="flex flex-col gap-6">
        <div :for={message <- @messages} class="flex flex-col gap-1.5">
          <p class="nb-eyebrow">{if message.role == "user", do: "You", else: "SuperX"}</p>

          <p class="max-w-[68ch] whitespace-pre-wrap leading-[1.6]">{message.content}</p>

          <%!-- What it actually did, so the prose isn't the only evidence. --%>
          <ul
            :if={message.tool_calls != []}
            class="mt-1 flex flex-col gap-0.5 border-l border-border pl-3"
          >
            <li :for={call <- message.tool_calls} class="nb-mono text-[11px] text-faint">
              {call["summary"]}
            </li>
          </ul>
        </div>

        <p :if={@thinking} class="nb-mono text-[11px] text-faint">working…</p>
      </div>

      <form phx-submit="ask" class="mt-9 border-t border-border pt-5">
        <label class="label" for="question">
          Ask something
          <span class="nb-mono ml-2 font-normal text-faint">{Ask.credit_cost()} credits</span>
        </label>
        <textarea
          id="question"
          name="question"
          rows="3"
          class="textarea"
          placeholder="How is my account doing?"
          disabled={@thinking}
        >{@draft}</textarea>
        <div class="mt-3">
          <button type="submit" class="btn-primary" disabled={@thinking}>
            {if @thinking, do: "Working…", else: "Send"}
          </button>
        </div>
      </form>
    </div>

    <section :if={@chats != []} class="mt-9 border-t border-border pt-6">
      <p class="nb-eyebrow mb-3">Earlier</p>
      <ul class="flex flex-col">
        <li
          :for={chat <- @chats}
          class="flex items-baseline gap-4 border-b border-border py-2 first:border-t"
        >
          <.link patch={~p"/ask/#{chat.id}"} class="hover-ember flex-1 truncate text-[13px]">
            {chat.title || "Untitled"}
          </.link>
          <span class="nb-mono text-[11px] text-faint">{ago(chat.updated_at)}</span>
          <button phx-click="delete_chat" phx-value-id={chat.id} class="act-danger text-xs">
            Delete
          </button>
        </li>
      </ul>
    </section>
    """
  end
end
