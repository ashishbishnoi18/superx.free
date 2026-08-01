defmodule SuperX.Engage.Replier do
  @moduledoc """
  Drafts replies in the user's voice, and scores what's worth replying to.

  Replies are metered against `replies_day` rather than credits, because
  they're the volume action in this product and a per-reply credit charge
  would make the sensible behaviour — triaging fifty mentions — feel
  expensive.
  """

  require Logger

  alias SuperX.{AI, Billing, Content}
  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Engage
  alias SuperX.Engage.Engagement

  @doc """
  Writes a reply to an engagement and puts it on its shelf.
  """
  @spec draft(User.t(), XAccount.t(), Engagement.t()) ::
          {:ok, map()} | {:error, term()} | {:error, :quota_exceeded, map()}
  def draft(%User{} = user, %XAccount{} = account, %Engagement{} = engagement) do
    with {:ok, text} <- write(user, account, engagement_prompt(account, engagement)) do
      Engage.create_draft(%{
        engagement_id: engagement.id,
        user_id: user.id,
        text: text,
        model: AI.writer_model()
      })
    end
  end

  @doc "Drafts a private reply from the recent messages in a DM thread."
  def draft_direct_message(%User{} = user, %XAccount{} = account, handle, messages)
      when is_list(messages) do
    case List.last(messages) do
      %{direction: "inbound"} ->
        write(user, account, direct_message_prompt(account, handle, messages))

      _ ->
        {:error, :nothing_to_reply_to}
    end
  end

  defp write(user, account, prompt) do
    with {:ok, voice} <- Content.get_or_create_voice_profile(account),
         {:ok, _quota} <- claim(user) do
      case ask(voice, account, prompt) do
        {:ok, text} ->
          {:ok, text}

        {:error, reason} ->
          # The user shouldn't lose a reply from their daily allowance
          # because our provider failed.
          Billing.release(user, "replies_day", 1)
          {:error, reason}
      end
    end
  end

  defp claim(user) do
    case Billing.claim(user, "replies_day", 1) do
      {:ok, quota} -> {:ok, quota}
      {:error, :quota_exceeded, details} -> {:error, :quota_exceeded, details}
    end
  end

  defp engagement_prompt(account, engagement) do
    """
    Someone posted this on X:

    <post>
    @#{engagement.author_handle}: #{engagement.text}
    </post>

    Write a reply from #{account.display_name || "@" <> account.handle}.

    A reply is a conversation, not a broadcast. Say one thing, briefly.
    React to what they actually said rather than restating it. If you have
    nothing to add, say something short and human instead of padding.

    Do not open with "Great point" or "This." Do not compliment the post.
    Do not pitch anything. Do not use hashtags. Stay well under 280
    characters — most good replies are under 120.
    """
  end

  defp direct_message_prompt(account, handle, messages) do
    transcript =
      messages
      |> Enum.take(-8)
      |> Enum.map_join("\n", fn message ->
        speaker = if message.direction == "outbound", do: "You", else: "@#{handle || "them"}"
        "#{speaker}: #{message.text}"
      end)

    """
    This is a private X conversation between #{account.display_name || "@" <> account.handle}
    and @#{handle || "the other person"}:

    <conversation>
    #{transcript}
    </conversation>

    Write the next message from #{account.display_name || "@" <> account.handle}.

    A direct message is a conversation, not a broadcast. Respond to the
    latest thing they said, while respecting what was already said in the
    thread. Say one thing, briefly. Do not pitch anything unless the thread
    is already discussing it. Do not use hashtags. Stay well under 280
    characters — most good replies are under 120.
    """
  end

  defp ask(voice, account, prompt) do
    schema = %{
      type: "object",
      properties: %{
        reply: %{type: "string", description: "The reply text. Under 280 characters."}
      },
      required: ["reply"]
    }

    case AI.structured(prompt, schema,
           system: SuperX.AI.Prompts.writer_system(voice, account),
           model: AI.writer_model(),
           temperature: 0.9,
           # Generous for a 280-character reply because the budget also has
           # to cover a reasoning model's thinking; too tight and it returns
           # without ever calling the tool.
           max_tokens: 2000,
           tool_description: "Return the reply."
         ) do
      {:ok, %{"reply" => reply}} when is_binary(reply) ->
        text = String.trim(reply)

        # The model occasionally runs long despite the instruction; a reply
        # that can't post is worse than a truncated one.
        {:ok, String.slice(text, 0, 280)}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      error ->
        error
    end
  end

  @doc """
  Scores a batch of engagements for how worth answering they are.

  One call for the whole batch rather than one per item: this runs on
  every poll, and per-item calls would dominate both latency and cost.
  Falls back to the heuristic when no LLM is configured.
  """
  def score(%XAccount{} = account, engagements) when is_list(engagements) do
    cond do
      engagements == [] ->
        {:ok, []}

      not AI.configured?() ->
        {:ok, Enum.map(engagements, &%{&1 | priority: Engagement.heuristic_priority(&1)})}

      true ->
        do_score(account, engagements)
    end
  end

  defp do_score(account, engagements) do
    numbered =
      engagements
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {e, i} ->
        "#{i}. @#{e.author_handle} (#{e.author_followers} followers): #{e.text}"
      end)

    prompt = """
    These people are talking to or near @#{account.handle}, whose account is
    about: #{account.description || "not specified"}.

    <items>
    #{numbered}
    </items>

    Score each 0-100 for how worth replying to it is. High means a real
    question, a substantive disagreement, or someone with genuine reach
    engaging seriously. Low means spam, engagement bait, one-word replies,
    and generic praise that has nothing to respond to.

    Give a short reason for anything you score above 70.
    """

    schema = %{
      type: "object",
      properties: %{
        scores: %{
          type: "array",
          items: %{
            type: "object",
            properties: %{
              index: %{type: "integer"},
              score: %{type: "integer"},
              reason: %{type: "string"}
            },
            required: ["index", "score"]
          }
        }
      },
      required: ["scores"]
    }

    case AI.structured(prompt, schema,
           model: AI.utility_model(),
           max_tokens: 1500,
           thinking: false,
           tool_description: "Return a score for every item."
         ) do
      {:ok, %{"scores" => scores}} ->
        by_index = Map.new(scores, &{&1["index"], &1})

        {:ok,
         engagements
         |> Enum.with_index(1)
         |> Enum.map(fn {e, i} ->
           case by_index[i] do
             %{"score" => score} = entry ->
               %{e | priority: clamp(score), priority_reason: entry["reason"]}

             _ ->
               %{e | priority: Engagement.heuristic_priority(e)}
           end
         end)}

      {:error, reason} ->
        Logger.warning("Engagement scoring failed: #{inspect(reason)}")
        {:ok, Enum.map(engagements, &%{&1 | priority: Engagement.heuristic_priority(&1)})}
    end
  end

  defp clamp(n) when is_integer(n), do: n |> max(0) |> min(100)
  defp clamp(_), do: 0
end
