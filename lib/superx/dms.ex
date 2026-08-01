defmodule SuperX.DMs do
  @moduledoc """
  The private inbox boundary: account-scoped storage, availability checks,
  and user-authorised sends.

  Private reads and writes both use X's own API with the account's OAuth
  grant. Unlike the public-data workloads routed through twitterapi.io, DM
  history is small and cannot be read without the user's authorisation.

  `sync/1` reads the account-wide `/2/dm_events` feed, which is the right
  source for conversations with other people. One thing that surprises you
  when testing: a message you send to yourself never appears there. It is
  retrievable through the per-conversation endpoints, so an empty sync on
  an account whose only message is a self-DM is X behaving as designed,
  not a parsing failure — confirmed against the live API rather than
  inferred.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SuperX.Accounts
  alias SuperX.Accounts.XAccount
  alias SuperX.DMs.{Conversation, Message}
  alias SuperX.Repo
  alias SuperX.X

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
      account.reauth_needed -> :reauthorize
      not Enum.all?(@required_scopes, &(&1 in account.scopes)) -> :reauthorize
      true -> :ready
    end
  end

  @doc """
  Fetches and stores the account's recent one-to-one DM history.

  X retains 30 days of events on this endpoint. Event ids are the durable
  deduplication key, so overlapping scheduled runs and locally recorded sends
  converge on the same stored message.
  """
  def sync(%XAccount{} = account) do
    with :ok <- ensure_sync_ready(account),
         {:ok, token, account} <- X.Tokens.fresh_token(account),
         {:ok, response} <- X.get_dm_events(token, event_types: ["MessageCreate"]),
         {:ok, result} <- store_sync(account, response) do
      {:ok, result}
    else
      {:error, {:http_error, 403, body}} ->
        {:error, {:dm_permission_tier_required, body}}

      error ->
        error
    end
  end

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

  defp ensure_sync_ready(account) do
    case availability(account) do
      :ready ->
        :ok

      :disabled ->
        {:error, :disabled}

      :reauthorize ->
        flag_dm_reauth(account)
    end
  end

  defp flag_dm_reauth(%XAccount{reauth_needed: true}), do: {:error, :reauth_required}

  defp flag_dm_reauth(account) do
    case Accounts.flag_reauth(account, "DM access was not granted. Reconnect this account.") do
      {:ok, _account} -> {:error, :reauth_required}
      {:error, reason} -> {:error, {:reauth_flag_failed, reason}}
    end
  end

  defp store_sync(account, %{events: events, users: users}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    conversations =
      events
      |> Enum.map(&normalise_message_event/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.group_by(& &1.x_conversation_id)

    Repo.transaction(fn ->
      Enum.reduce(conversations, %{conversations: 0, messages: 0, skipped: 0}, fn
        {conversation_id, messages}, counts ->
          sync_conversation(account, conversation_id, messages, users, now, counts)
      end)
    end)
  end

  defp sync_conversation(account, conversation_id, messages, users, now, counts) do
    case one_to_one_participant(conversation_id, account.x_user_id) do
      nil ->
        # A group id has no single safe send address. Filing it under the
        # last sender would make a reply leave the intended conversation.
        %{counts | skipped: counts.skipped + length(messages)}

      participant_id ->
        profile = Map.get(users, participant_id, %{})
        latest = Enum.max_by(messages, &DateTime.to_unix(&1.sent_at, :microsecond))

        attrs =
          %{
            x_conversation_id: conversation_id,
            participant_x_user_id: participant_id
          }
          |> put_present(:participant_handle, profile["username"])
          |> put_present(:participant_name, profile["name"])
          |> put_present(:participant_avatar_url, profile["profile_image_url"])

        with {:ok, conversation} <- upsert_conversation(account, attrs),
             {:ok, conversation} <- refresh_synced_conversation(conversation, latest, now),
             :ok <- upsert_messages(account, conversation, messages) do
          %{
            counts
            | conversations: counts.conversations + 1,
              messages: counts.messages + length(messages)
          }
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp refresh_synced_conversation(conversation, latest, now) do
    attrs =
      if newer_message?(latest, conversation.last_message_at) do
        %{
          last_message_text: latest.text,
          last_message_at: latest.sent_at,
          last_synced_at: now
        }
      else
        %{last_synced_at: now}
      end

    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  defp newer_message?(_message, nil), do: true

  defp newer_message?(message, last_message_at) do
    DateTime.compare(message.sent_at, last_message_at) in [:gt, :eq]
  end

  defp upsert_messages(account, conversation, messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      changeset =
        %Message{x_account_id: account.id, conversation_id: conversation.id}
        |> Message.changeset(%{
          x_message_id: message.x_message_id,
          sender_x_user_id: message.sender_x_user_id,
          direction: direction(message.sender_x_user_id, account.x_user_id),
          text: message.text,
          sent_at: message.sent_at
        })

      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:x_account_id, :x_message_id]
           ) do
        {:ok, _message} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalise_message_event(%{
         "event_type" => "MessageCreate",
         "id" => id,
         "dm_conversation_id" => conversation_id,
         "sender_id" => sender_id,
         "text" => text,
         "created_at" => created_at
       })
       when is_binary(id) and is_binary(conversation_id) and is_binary(sender_id) and
              is_binary(text) and text != "" and is_binary(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, sent_at, _offset} ->
        %{
          x_message_id: id,
          x_conversation_id: conversation_id,
          sender_x_user_id: sender_id,
          text: text,
          sent_at: DateTime.truncate(sent_at, :second)
        }

      _invalid_timestamp ->
        nil
    end
  end

  defp normalise_message_event(_event), do: nil

  defp one_to_one_participant(conversation_id, own_x_user_id) do
    case String.split(conversation_id, "-") do
      [^own_x_user_id, participant_id] -> participant_id
      [participant_id, ^own_x_user_id] -> participant_id
      _group_or_unknown -> nil
    end
  end

  defp direction(sender_id, own_x_user_id) when sender_id == own_x_user_id, do: "outbound"
  defp direction(_sender_id, _own_x_user_id), do: "inbound"

  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value), do: Map.put(attrs, key, value)

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
