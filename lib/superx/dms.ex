defmodule SuperX.DMs do
  @moduledoc """
  The private inbox boundary: account-scoped storage, availability checks,
  and user-authorised sends.

  Private reads and writes both use X's own API with the account's OAuth
  grant. Unlike the public-data workloads routed through twitterapi.io, DM
  history is small and cannot be read without the user's authorisation.

  `sync/1` reads both the legacy `/2/dm_events` feed and the encrypted Chat
  API. Both converge on the same account-scoped conversation and message
  rows, with X's event id as the deduplication key.

  XChat private keys are acceptable here only because each operator runs
  their own instance. Hosting SuperX for other people would put their chat
  identities on somebody else's server, which X explicitly warns against and
  which this design does not make safe.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias SuperX.Accounts
  alias SuperX.Accounts.XAccount
  alias SuperX.DMs.{Conversation, Message}
  alias SuperX.Repo
  alias SuperX.X
  alias SuperX.XChat.Identity

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
         {:ok, legacy_result} <- store_sync(account, response),
         {:ok, xchat_result} <- sync_xchat(account, token) do
      {:ok, merge_counts(legacy_result, xchat_result)}
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
         {:ok, result} <- send_message(account, conversation, token, text),
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
          sync_conversation(account, conversation_id, messages, users, now, false, counts)
      end)
    end)
  end

  defp sync_conversation(account, conversation_id, messages, users, now, encrypted, counts) do
    case one_to_one_participant(conversation_id, account.x_user_id) do
      nil ->
        # A group id has no single safe send address. Filing it under the
        # last sender would make a reply leave the intended conversation.
        %{counts | skipped: counts.skipped + length(messages)}

      participant_id ->
        profile = Map.get(users, participant_id, %{})
        latest = latest_message(messages)

        attrs =
          %{
            x_conversation_id: conversation_id,
            participant_x_user_id: participant_id
          }
          |> maybe_mark_encrypted(encrypted)
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

  defp latest_message([]), do: nil

  defp latest_message(messages) do
    Enum.max_by(messages, &DateTime.to_unix(&1.sent_at, :microsecond))
  end

  defp refresh_synced_conversation(conversation, nil, now) do
    conversation
    |> Conversation.changeset(%{last_synced_at: now})
    |> Repo.update()
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
    case String.split(conversation_id, ~r/[:-]/) do
      [^own_x_user_id, participant_id] -> participant_id
      [participant_id, ^own_x_user_id] -> participant_id
      _group_or_unknown -> nil
    end
  end

  defp direction(sender_id, own_x_user_id) when sender_id == own_x_user_id, do: "outbound"
  defp direction(_sender_id, _own_x_user_id), do: "inbound"

  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value), do: Map.put(attrs, key, value)

  defp maybe_mark_encrypted(attrs, true), do: Map.put(attrs, :encrypted, true)
  defp maybe_mark_encrypted(attrs, false), do: attrs

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

  # --- XChat ---------------------------------------------------------------

  defp sync_xchat(account, token) do
    client = xchat_client()

    if client.available?() do
      with {:ok, identity} <- ensure_xchat_identity(account, token, client),
           {:ok, response} <- X.get_chat_conversations(token),
           conversations <- direct_chat_conversations(response.conversations, account.x_user_id),
           {:ok, signing_keys} <- chat_signing_keys(token, conversations, account.x_user_id),
           {:ok, batches} <-
             decrypt_chat_conversations(
               account,
               identity,
               conversations,
               signing_keys,
               token,
               client
             ),
           {:ok, result} <- store_xchat_sync(account, batches, response.users) do
        {:ok, result}
      end
    else
      {:ok, empty_counts()}
    end
  end

  defp send_message(account, %{encrypted: true} = conversation, token, text) do
    client = xchat_client()

    with true <- client.available?(),
         {:ok, identity} <- ensure_xchat_identity(account, token, client),
         {:ok, signing_keys} <-
           fetch_signing_keys(token, [account.x_user_id, conversation.participant_x_user_id]),
         {:ok, history} <- X.get_chat_conversation_events(token, conversation.x_conversation_id),
         {:ok, encrypted} <-
           client.encrypt_message(
             crypto_params(account, identity, history, signing_keys)
             |> Map.merge(%{
               "conversation_id" => conversation.x_conversation_id,
               "text" => text
             })
           ),
         {:ok, result} <-
           X.send_chat_message(token, conversation.x_conversation_id, encrypted) do
      {:ok, result}
    else
      false -> {:error, :xchat_unavailable}
      error -> error
    end
  end

  defp send_message(_account, conversation, token, text) do
    X.create_dm(token, conversation.participant_x_user_id, text)
  end

  defp ensure_xchat_identity(account, token, client) do
    with {:ok, identity} <- get_or_create_xchat_identity(account, client),
         {:ok, identity} <- register_xchat_identity(identity, account, token) do
      {:ok, identity}
    end
  end

  # The account row serialises first-time generation. Registering two identities
  # would spend the endpoint's strict daily write allowance and strand whichever
  # private half lost the race.
  defp get_or_create_xchat_identity(account, client) do
    Repo.transaction(fn ->
      XAccount
      |> where(id: ^account.id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

      case Repo.get_by(Identity, x_account_id: account.id) do
        %Identity{} = identity ->
          {:ok, identity}

        nil ->
          with {:ok, generated} <- client.register_keys(),
               {:ok, private_key, key_version, registration} <- identity_parts(generated) do
            account
            |> Identity.create_changeset(private_key, key_version, registration)
            |> Repo.insert()
          end
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp identity_parts(%{
         "private_key" => private_key,
         "key_version" => key_version,
         "registration" => registration
       })
       when is_binary(private_key) and private_key != "" and is_binary(key_version) and
              key_version != "" and is_map(registration) do
    {:ok, private_key, key_version, registration}
  end

  defp identity_parts(_generated), do: {:error, :invalid_xchat_identity}

  defp register_xchat_identity(
         %Identity{registered_at: registered_at} = identity,
         _account,
         _token
       )
       when not is_nil(registered_at),
       do: {:ok, identity}

  defp register_xchat_identity(identity, account, token) do
    Repo.transaction(fn ->
      identity =
        Identity
        |> where(id: ^identity.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if identity.registered_at do
        identity
      else
        with {:ok, registered} <-
               X.register_chat_public_key(token, account.x_user_id, identity.registration),
             version <- assigned_key_version(registered, identity, account, token),
             {:ok, identity} <-
               identity
               |> Identity.registered_changeset(
                 DateTime.utc_now() |> DateTime.truncate(:second),
                 version
               )
               |> Repo.update() do
          identity
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
  end

  # The registration response is the first authority on the version X chose.
  # Reading the published key back and matching our own public half covers
  # the case where it does not carry one, because guessing wrong here is
  # silent: every signature check fails much later, against a valid key.
  defp assigned_key_version(response, identity, account, token) when is_map(response) do
    response["version"] || response["public_key_version"] ||
      published_key_version(identity, account, token)
  end

  defp assigned_key_version(_response, identity, account, token),
    do: published_key_version(identity, account, token)

  defp published_key_version(identity, account, token) do
    with public_key when is_binary(public_key) <-
           get_in(identity.registration, ["public_key", "public_key"]),
         {:ok, keys} <- X.get_chat_user_public_keys(token, account.x_user_id),
         %{"public_key_version" => version} <-
           Enum.find(keys, &(&1["public_key"] == public_key)) do
      version
    else
      _unmatched -> nil
    end
  end

  defp direct_chat_conversations(conversations, own_x_user_id) do
    Enum.flat_map(conversations, fn conversation ->
      participant_id = chat_participant(conversation, own_x_user_id)

      if conversation["type"] == "direct" and participant_id do
        [{conversation, participant_id}]
      else
        []
      end
    end)
  end

  defp chat_participant(conversation, own_x_user_id) do
    participant_ids = conversation["participant_ids"] || []

    Enum.find(participant_ids, &(&1 != own_x_user_id)) ||
      one_to_one_participant(conversation["id"] || "", own_x_user_id)
  end

  defp chat_signing_keys(token, conversations, own_x_user_id) do
    user_ids =
      conversations
      |> Enum.flat_map(fn {_conversation, participant_id} -> [own_x_user_id, participant_id] end)
      |> Enum.uniq()

    fetch_signing_keys(token, user_ids)
  end

  defp fetch_signing_keys(token, user_ids) do
    Enum.reduce_while(user_ids, {:ok, []}, fn user_id, {:ok, entries} ->
      case X.get_chat_user_public_keys(token, user_id) do
        {:ok, keys} ->
          new_entries = Enum.flat_map(keys, &signing_key_entry(user_id, &1))
          {:cont, {:ok, entries ++ new_entries}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp signing_key_entry(user_id, key) do
    with public_key_version when is_binary(public_key_version) <- key["public_key_version"],
         public_key when is_binary(public_key) <- key["signing_public_key"],
         identity_public_key when is_binary(identity_public_key) <- key["public_key"],
         signature when is_binary(signature) <- key["identity_public_key_signature"] do
      [
        %{
          "userId" => user_id,
          "publicKeyVersion" => public_key_version,
          "publicKey" => public_key,
          "identityPublicKey" => identity_public_key,
          "identityPublicKeySignature" => signature
        }
      ]
    else
      _missing_field -> []
    end
  end

  defp decrypt_chat_conversations(
         account,
         identity,
         conversations,
         signing_keys,
         token,
         client
       ) do
    Enum.reduce_while(conversations, {:ok, []}, fn {conversation, participant_id},
                                                   {:ok, batches} ->
      conversation_id = conversation["id"]

      with {:ok, history} <- X.get_chat_conversation_events(token, conversation_id),
           {:ok, decrypted} <-
             client.decrypt_events(crypto_params(account, identity, history, signing_keys)),
           {:ok, events, skipped} <- normalise_decrypted_events(decrypted, conversation_id) do
        batch = %{
          conversation_id: conversation_id,
          participant_id: participant_id,
          messages: events,
          skipped: skipped
        }

        {:cont, {:ok, [batch | batches]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, batches} -> {:ok, Enum.reverse(batches)}
      error -> error
    end
  end

  defp crypto_params(account, identity, history, signing_keys) do
    events =
      (history.key_events ++ Enum.map(history.events, & &1["encoded_event"]))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    %{
      "private_key" => identity.private_key,
      "key_version" => identity.key_version,
      "user_id" => account.x_user_id,
      "events" => events,
      "signing_keys" => signing_keys
    }
  end

  defp normalise_decrypted_events(%{"events" => events} = result, conversation_id)
       when is_list(events) do
    messages =
      events
      |> Enum.map(&normalise_xchat_event(&1, conversation_id))
      |> Enum.reject(&is_nil/1)

    rejected = length(events) - length(messages)
    errors = if is_map(result["errors"]), do: map_size(result["errors"]), else: 0

    # A message that will not decrypt and one that is simply not text both
    # landed in the same silent counter, which made an inbox that stayed
    # empty impossible to diagnose. These carry XDK failure reasons, not
    # plaintext.
    if errors > 0 do
      Logger.warning(
        "XChat could not decrypt #{errors} event(s) in #{conversation_id}: " <>
          inspect(result["errors"])
      )
    end

    {:ok, messages, rejected + errors}
  end

  defp normalise_decrypted_events(_result, _conversation_id),
    do: {:error, :invalid_xchat_decryption}

  defp normalise_xchat_event(
         %{
           "type" => "message",
           "id" => id,
           "senderId" => sender_id,
           "createdAtMsec" => created_at,
           "content" => %{"text" => text}
         },
         conversation_id
       )
       when is_binary(id) and id != "" and is_binary(sender_id) and sender_id != "" and
              is_binary(text) and text != "" do
    with {:ok, milliseconds} <- milliseconds(created_at),
         {:ok, sent_at} <- DateTime.from_unix(milliseconds, :millisecond) do
      %{
        x_message_id: id,
        x_conversation_id: conversation_id,
        sender_x_user_id: sender_id,
        text: text,
        sent_at: DateTime.truncate(sent_at, :second)
      }
    else
      _invalid_time -> nil
    end
  end

  defp normalise_xchat_event(_event, _conversation_id), do: nil

  defp milliseconds(value) when is_integer(value), do: {:ok, value}

  defp milliseconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {milliseconds, ""} -> {:ok, milliseconds}
      _invalid -> :error
    end
  end

  defp milliseconds(_value), do: :error

  defp store_xchat_sync(account, batches, users) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      Enum.reduce(batches, empty_counts(), fn batch, counts ->
        counts = %{counts | skipped: counts.skipped + batch.skipped}

        sync_conversation(
          account,
          batch.conversation_id,
          batch.messages,
          users,
          now,
          true,
          counts
        )
      end)
    end)
  end

  defp merge_counts(left, right) do
    %{
      conversations: left.conversations + right.conversations,
      messages: left.messages + right.messages,
      skipped: left.skipped + right.skipped
    }
  end

  defp empty_counts, do: %{conversations: 0, messages: 0, skipped: 0}

  defp xchat_client do
    Application.get_env(:superx, :xchat_client, SuperX.XChat)
  end
end
