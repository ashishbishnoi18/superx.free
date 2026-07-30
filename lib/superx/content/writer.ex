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
      write(user, account, voice, topic, kind, source, 1)
    end
  end

  # Attempts is bounded at two: one with the source, one without it. A
  # model that has already latched onto the reference's phrasing tends to
  # keep doing so, so the retry removes the reference rather than asking
  # more politely.
  defp write(user, account, voice, topic, kind, source, attempt) do
    prompt =
      case source do
        nil -> Prompts.write_from_topic(topic, Voice.examples(account, voice))
        post -> Prompts.rewrite_from_corpus(post, topic, Voice.examples(account, voice))
      end

    case AI.structured(prompt, Prompts.post_schema(),
           system: Prompts.writer_system(voice, account),
           model: AI.writer_model(),
           temperature: 1.0,
           max_tokens: 1200,
           tool_description: "Return the written post."
         ) do
      {:ok, %{"segments" => segments}} when is_list(segments) and segments != [] ->
        text = segments |> Enum.map_join(" ", &to_string/1) |> String.trim()

        cond do
          text == "" ->
            retry_or_fail(user, account, voice, topic, kind, source, attempt, :blank)

          source && attempt == 1 && derivative?(text, source.text) ->
            # The whole premise is borrowing shape, not words. A post that
            # reuses the reference's phrasing would publish someone else's
            # line under this user's name.
            Logger.info("Discarding derivative draft; rewriting without the reference")
            write(user, account, voice, topic, kind, nil, attempt + 1)

          true ->
            store(user, account, kind, source, segments)
        end

      # A tool call with no arguments — the model answered the shape but
      # not the question. Seen in practice, so it retries rather than
      # surfacing as a failed generation the user paid for.
      {:ok, other} ->
        Logger.debug("Writer returned no segments: #{inspect(other)}")
        retry_or_fail(user, account, voice, topic, kind, source, attempt, {:empty_generation, other})

      # A reasoning model that spent its turn thinking and never called the
      # tool. Transient, so it gets the same retry as an empty call rather
      # than costing the user a credit for nothing.
      {:error, {:no_tool_use, _} = reason} ->
        retry_or_fail(user, account, voice, topic, kind, source, attempt, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_or_fail(user, account, voice, topic, kind, source, attempt, reason) do
    if attempt < 2 do
      write(user, account, voice, topic, kind, source, attempt + 1)
    else
      {:error, reason}
    end
  end

  defp store(user, account, kind, source, segments) do
    Content.create_generation(%{
      user_id: user.id,
      x_account_id: account.id,
      segments: Enum.map(segments, &%{"text" => String.trim(to_string(&1)), "media_ids" => []}),
      kind: kind,
      source_corpus_post_id: source && source.id,
      source_likes: source && source.likes,
      model: AI.writer_model(),
      credits_cost: @credit_cost,
      score: source && source.engagement_score
    })
  end

  # Shared runs of six words are the signature of template substitution:
  # the model keeps the reference's skeleton and swaps the nouns, which
  # leaves its distinctive closing line intact.
  #
  # Six, not five: at five this fires on ordinary idiom — "one of the
  # things that" is exactly five words and appears in unrelated posts all
  # the time. Six still catches the real cases, which turn on a lifted
  # clause rather than a lifted phrase.
  @ngram 6

  @doc false
  def derivative?(text, source_text) do
    theirs = ngrams(source_text)

    text
    |> ngrams()
    |> Enum.any?(&MapSet.member?(theirs, &1))
  end

  defp ngrams(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.chunk_every(@ngram, 1, :discard)
    |> MapSet.new()
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
