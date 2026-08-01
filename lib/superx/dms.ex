defmodule SuperX.DMs do
  @moduledoc """
  The private inbox boundary: account-scoped storage, availability checks,
  and user-authorised sends.

  Incoming sync deliberately stops at `sync/1`. twitterapi.io's only
  published history endpoint requires X login cookies, a proxy, and a known
  participant; it cannot enumerate the OAuth user's inbox. SuperX does not
  collect passwords or browser cookies to bridge that gap.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SuperX.Accounts.XAccount
  alias SuperX.DMs.{Conversation, Message}
  alias SuperX.Repo

  @required_scopes ~w(dm.read dm.write)

  @doc "Conversations for one account, newest activity first."
  def list_conversations(%XAccount{} = account) do
    Conversation
    |> where(x_account_id: ^account.id)
    |> order_by([c], desc_nulls_last: c.last_message_at, desc: c.inserted_at)
    |> Repo.all()
  end

  @doc "Loads one account-owned conversation and its chronological thread."
  def get_conversation(%XAccount{} = account, id) do
    messages = from(m in Message, order_by: [asc: m.sent_at, asc: m.inserted_at])

    Conversation
    |> Repo.get_by(id: id, x_account_id: account.id)
    |> Repo.preload(messages: messages)
  end

  @doc "Creates or refreshes the participant metadata for a one-to-one thread."
  def upsert_conversation(%XAccount{} = account, attrs) do
    participant_id = attrs[:participant_x_user_id] || attrs["participant_x_user_id"]

    conversation =
      Repo.get_by(Conversation,
        x_account_id: account.id,
        participant_x_user_id: participant_id
      ) || %Conversation{x_account_id: account.id}

    conversation
    |> Conversation.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Whether this account can make a DM API call without re-authorising."
  def availability(%XAccount{} = account) do
    cond do
      not SuperX.X.dms_enabled?() -> :disabled
      not Enum.all?(@required_scopes, &(&1 in account.scopes)) -> :reauthorize
      true -> :ready
    end
  end

  @doc """
  Sync seam for incoming conversations.

  It makes no upstream request while the configured read provider lacks an
  API-key endpoint that can enumerate an OAuth user's DM events.
  """
  def sync(%XAccount{} = account), do: SuperX.TwitterAPI.direct_messages(account.x_user_id)

  @doc "Sends and records one reply through X's OAuth API."
  def send_reply(%XAccount{} = account, conversation_id, text) do
    with {:ok, text} <- normalise_text(text),
         :ok <- ensure_ready(account),
         %Conversation{} = conversation <- get_conversation(account, conversation_id),
         {:ok, token, account} <- SuperX.X.Tokens.fresh_token(account),
         {:ok, result} <- SuperX.X.create_dm(token, conversation.participant_x_user_id, text),
         {:ok, message} <- store_sent(account, conversation, result, text) do
      {:ok, message}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp normalise_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :empty_message}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalise_text(_text), do: {:error, :empty_message}

  defp ensure_ready(account) do
    case availability(account) do
      :ready -> :ok
      status -> {:error, status}
    end
  end

  defp store_sent(account, conversation, result, text) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    message =
      %Message{x_account_id: account.id, conversation_id: conversation.id}
      |> Message.changeset(%{
        x_message_id: result.message_id,
        sender_x_user_id: account.x_user_id,
        direction: "outbound",
        text: text,
        sent_at: now
      })

    updated_conversation =
      Conversation.changeset(conversation, %{
        x_conversation_id: result.conversation_id,
        last_message_text: text,
        last_message_at: now
      })

    Multi.new()
    |> Multi.insert(:message, message)
    |> Multi.update(:conversation, updated_conversation)
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message}} -> {:ok, message}
      {:error, _step, reason, _changes} -> {:error, {:store_failed, reason}}
    end
  end
end
