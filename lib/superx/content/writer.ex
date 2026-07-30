defmodule SuperX.Content.Writer do
  @moduledoc """
  Writes posts in a user's voice, seeded by the corpus.

  The loop is: pick a topic the user actually posts about, retrieve a
  high-performing post as a structural template, then rewrite that
  structure onto the topic in the user's voice.

  Credits are claimed before the model call and refunded if it fails, so
  a provider outage never costs the user anything.
  """

  require Logger

  alias SuperX.{AI, Billing, Content}
  alias SuperX.AI.Prompts
  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Content.{Corpus, Generation, Voice, VoiceProfile}

  # One shelf item costs one credit. Ask, which runs a longer agentic
  # loop, costs more — see SuperX.Content.Ask.
  @credit_cost 1

  @doc """
  Generates one post and puts it on the shelf.

  Returns `{:error, :quota_exceeded, details}` when the user is out of
  credits, which the UI turns into an upgrade prompt.
  """
  @spec generate(User.t(), XAccount.t(), keyword()) ::
          {:ok, Generation.t()} | {:error, term()} | {:error, :quota_exceeded, map()}
  def generate(%User{} = user, %XAccount{} = account, opts \\ []) do
    with {:ok, voice} <- Content.get_or_create_voice_profile(account),
         {:ok, _balance} <- claim_credit(user) do
      case do_generate(user, account, voice, opts) do
        {:ok, generation} ->
          {:ok, generation}

        {:error, reason} ->
          # The user shouldn't pay for our failure.
          Billing.refund_credits(user, @credit_cost, ref_type: "generation")
          {:error, reason}
      end
    end
  end

  defp claim_credit(user) do
    case Billing.spend_credits(user, @credit_cost, "generation", ref_type: "generation") do
      {:ok, balance} -> {:ok, balance}
      {:error, :quota_exceeded, details} -> {:error, :quota_exceeded, details}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_generate(user, account, voice, opts) do
    topic = opts[:topic] || pick_topic(voice)
    kind = opts[:kind] || "for_you"

    if is_nil(topic) do
      {:error, :no_topics}
    else
      source = opts[:source] || pick_source(account, voice, topic)
      examples = Voice.examples(account, voice)

      prompt =
        case source do
          nil -> Prompts.write_from_topic(topic, examples)
          post -> Prompts.rewrite_from_corpus(post, topic, examples)
        end

      case AI.structured(prompt, Prompts.post_schema(),
             system: Prompts.writer_system(voice, account),
             model: AI.writer_model(),
             temperature: 1.0,
             max_tokens: 1200,
             tool_description: "Return the written post."
           ) do
        {:ok, %{"segments" => segments}} when segments != [] ->
          Content.create_generation(%{
            user_id: user.id,
            x_account_id: account.id,
            segments: Enum.map(segments, &%{"text" => String.trim(&1), "media_ids" => []}),
            kind: kind,
            source_corpus_post_id: source && source.id,
            source_likes: source && source.likes,
            model: AI.writer_model(),
            credits_cost: @credit_cost,
            score: source && source.engagement_score
          })

        {:ok, other} ->
          {:error, {:empty_generation, other}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Rotate through the user's topics rather than always taking the first,
  # or every generated post ends up about the same thing.
  defp pick_topic(%VoiceProfile{} = voice) do
    case VoiceProfile.topic_list(voice) do
      [] -> nil
      topics -> Enum.random(topics)
    end
  end

  defp pick_source(%XAccount{} = account, %VoiceProfile{} = voice, topic) do
    topics = VoiceProfile.topic_list(voice)

    # Prefer a post that matches the user's subject area; fall back to any
    # strong post, since structure transfers across topics anyway.
    candidates =
      case Corpus.candidates_for(account.id, topics, limit: 5) do
        [] -> Corpus.candidates_for(account.id, nil, limit: 5)
        found -> found
      end

    case candidates do
      [] ->
        Logger.debug("No corpus candidates for @#{account.handle} on #{inspect(topic)}")
        nil

      posts ->
        Enum.random(posts)
    end
  end

  @doc """
  Fills an account's shelf up to its target mix, one generation at a time.

  Stops early on quota exhaustion rather than burning through the rest of
  the batch and failing repeatedly.
  """
  def top_up(%User{} = user, %XAccount{} = account, targets) do
    deficit = Content.shelf_deficit(account, targets)

    Enum.reduce_while(deficit, {:ok, 0}, fn {kind, count}, {:ok, made} ->
      case generate_n(user, account, kind, count) do
        {:ok, n} -> {:cont, {:ok, made + n}}
        {:error, :quota_exceeded, _details} -> {:halt, {:ok, made}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp generate_n(_user, _account, _kind, 0), do: {:ok, 0}

  defp generate_n(user, account, kind, count) do
    Enum.reduce_while(1..count, {:ok, 0}, fn _i, {:ok, made} ->
      case generate(user, account, kind: kind) do
        {:ok, _generation} -> {:cont, {:ok, made + 1}}
        {:error, :quota_exceeded, details} -> {:halt, {:error, :quota_exceeded, details}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
