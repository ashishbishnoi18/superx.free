defmodule SuperX.Ask do
  @moduledoc """
  Chat with tools over the user's own account.

  Runs a bounded tool-use loop: the model may call tools, see results, and
  call again, up to a hard ceiling. The ceiling matters — a model that
  loops on a failing tool would otherwise burn the user's credits without
  producing anything.
  """

  import Ecto.Query

  require Logger

  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.{AI, Billing, Repo}
  alias SuperX.Ask.{Chat, Message, Tools}

  # One chat turn costs this regardless of how many tools it calls — the
  # user is buying an answer, not a token count.
  @credit_cost 3

  # Tool rounds per turn. Enough for "look something up, then act on it",
  # not enough to spiral.
  @max_rounds 5

  # --- Chats ---------------------------------------------------------------

  def list_chats(%User{} = user, limit \\ 30) do
    Chat
    |> where(user_id: ^user.id)
    |> order_by(desc: :updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_chat(%User{} = user, id) do
    Chat
    |> Repo.get_by(id: id, user_id: user.id)
    |> case do
      nil -> nil
      chat -> Repo.preload(chat, messages: from(m in Message, order_by: m.inserted_at))
    end
  end

  def create_chat(%User{} = user, %XAccount{} = account, title) do
    %Chat{}
    |> Chat.changeset(%{user_id: user.id, x_account_id: account.id, title: title})
    |> Repo.insert()
  end

  def delete_chat(%User{} = user, id) do
    case Repo.get_by(Chat, id: id, user_id: user.id) do
      nil -> {:error, :not_found}
      chat -> Repo.delete(chat)
    end
  end

  # --- Turns ---------------------------------------------------------------

  @doc """
  Runs one turn: records the user's message, lets the model work, records
  the reply.

  Credits are claimed up front and refunded if the model never produces an
  answer, matching how generation is metered elsewhere.
  """
  @spec ask(User.t(), XAccount.t(), Chat.t(), String.t()) ::
          {:ok, Message.t()} | {:error, term()} | {:error, :quota_exceeded, map()}
  def ask(%User{} = user, %XAccount{} = account, %Chat{} = chat, question) do
    with {:ok, _} <- claim(user),
         {:ok, _user_message} <- add_message(chat, "user", question) do
      history = history_for(chat)

      case run_loop(user, account, history) do
        {:ok, answer, tool_summaries} ->
          touch(chat)
          add_message(chat, "assistant", answer, tool_summaries, @credit_cost)

        {:error, reason} ->
          Billing.refund_credits(user, @credit_cost, ref_type: "ask", ref_id: chat.id)
          {:error, reason}
      end
    end
  end

  defp claim(user) do
    case Billing.spend_credits(user, @credit_cost, "ask", ref_type: "ask") do
      {:ok, balance} -> {:ok, balance}
      {:error, :quota_exceeded, details} -> {:error, :quota_exceeded, details}
      other -> other
    end
  end

  defp run_loop(user, account, messages, ctx \\ nil, round \\ 1, summaries \\ [])

  defp run_loop(_user, _account, _messages, _ctx, round, summaries) when round > @max_rounds do
    {:ok,
     "I looked into that but couldn't finish in a reasonable number of steps. Try asking for one thing at a time.",
     summaries}
  end

  defp run_loop(user, account, messages, ctx, round, summaries) do
    ctx = ctx || %{user: user, account: account}

    body = %{
      model: AI.writer_model(),
      max_tokens: 2000,
      system: system_prompt(account),
      messages: messages,
      tools: Tools.definitions()
    }

    case AI.raw(body) do
      {:ok, %{"content" => content, "stop_reason" => "tool_use"}} ->
        {results, new_summaries} = run_tools(content, ctx)

        run_loop(
          user,
          account,
          messages ++ [%{role: "assistant", content: content}, %{role: "user", content: results}],
          ctx,
          round + 1,
          summaries ++ new_summaries
        )

      {:ok, %{"content" => content}} ->
        {:ok, extract_text(content), summaries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_tools(content, ctx) do
    content
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.map(fn %{"id" => id, "name" => name, "input" => input} ->
      {result, summary} =
        try do
          Tools.run(name, input, ctx)
        rescue
          error ->
            Logger.warning("Ask tool #{name} crashed: #{inspect(error)}")
            {"That tool failed.", nil}
        end

      {%{type: "tool_result", tool_use_id: id, content: result}, summary}
    end)
    |> Enum.unzip()
    |> then(fn {results, summaries} -> {results, Enum.reject(summaries, &is_nil/1)} end)
  end

  defp extract_text(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", & &1["text"])
    |> String.trim()
  end

  defp system_prompt(account) do
    """
    You are SuperX, helping @#{account.handle} run their X account.

    You can read their analytics, queue, engagement inbox, contacts, and
    the library of high-performing posts, and you can draft and queue posts
    for them. You cannot publish — queueing is as far as it goes, and the
    user approves from the queue.

    Look things up rather than guessing. If they ask how the account is
    doing, read the analytics before answering. If they ask what to post
    about, look at what has worked.

    Never queue text the user hasn't seen and agreed to. Draft first, show
    it, then queue it if they say yes.

    Answer briefly and concretely. Plain prose, no headers or bullet lists
    unless the answer is genuinely a list. Say what's true — if the numbers
    are flat, say they're flat.
    """
  end

  defp history_for(%Chat{} = chat) do
    chat = Repo.preload(chat, messages: from(m in Message, order_by: m.inserted_at))

    chat.messages
    # Long histories cost tokens on every turn and rarely help; the recent
    # exchange is what the conversation is actually about.
    |> Enum.take(-20)
    |> Enum.map(&%{role: &1.role, content: &1.content})
  end

  defp add_message(chat, role, content, tool_calls \\ [], cost \\ 0) do
    %Message{}
    |> Message.changeset(%{
      chat_id: chat.id,
      role: role,
      content: content,
      tool_calls: Enum.map(tool_calls, &%{"summary" => &1}),
      credits_cost: cost
    })
    |> Repo.insert()
  end

  defp touch(%Chat{} = chat) do
    chat
    |> Ecto.Changeset.change(updated_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc "A short title derived from the opening question."
  def title_from(question) do
    question
    |> String.split(~r/\s+/)
    |> Enum.take(8)
    |> Enum.join(" ")
    |> String.slice(0, 70)
  end

  def credit_cost, do: @credit_cost
end
