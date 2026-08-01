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
      source =
        if Keyword.has_key?(opts, :source) do
          opts[:source]
        else
          pick_source(account, voice, topic)
        end

      inspiration = Voice.inspiration_posts(voice)

      write(user, account, voice, topic, kind, source, inspiration, 1)
    end
  end

  # Attempts are bounded at two. A model that has latched onto reference
  # phrasing tends to keep doing so, so a derivative draft spends the last
  # attempt without any reference material rather than asking more politely.
  defp write(user, account, voice, topic, kind, source, inspiration, attempt) do
    voice_examples = Voice.examples(account, voice)

    prompt =
      case source do
        nil -> Prompts.write_from_topic(topic, voice_examples, inspiration)
        post -> Prompts.rewrite_from_corpus(post, topic, voice_examples, inspiration)
      end

    reference_texts = reference_texts(source, inspiration)

    case AI.structured(prompt, Prompts.post_schema(),
           system: Prompts.writer_system(voice, account),
           model: AI.writer_model(),
           temperature: 1.0,
           # The budget has to cover thinking *and* the tool call. A
           # reasoning model given 1200 spends all of it working out the
           # reference's shape and returns having never called the tool,
           # which costs a retry and then fails the generation outright.
           max_tokens: 4000,
           tool_description: "Return the written post."
         ) do
      {:ok, %{"segments" => segments}} when is_list(segments) and segments != [] ->
        text = segments |> Enum.map_join(" ", &to_string/1) |> String.trim()

        cond do
          text == "" ->
            retry_or_fail(
              user,
              account,
              voice,
              topic,
              kind,
              source,
              inspiration,
              attempt,
              :blank
            )

          derivative_from_any?(text, reference_texts) ->
            # Named creators make phrase lifting more likely, so their posts
            # go through the same guard as corpus references. The clean retry
            # removes both kinds of material before the model sees them again.
            Logger.info("Discarding derivative draft; rewriting without reference material")
            retry_without_references(user, account, voice, topic, kind, attempt)

          true ->
            store(user, account, kind, source, segments)
        end

      # A tool call with no arguments — the model answered the shape but
      # not the question. Seen in practice, so it retries rather than
      # surfacing as a failed generation the user paid for.
      {:ok, other} ->
        Logger.debug("Writer returned no segments: #{inspect(other)}")

        retry_or_fail(
          user,
          account,
          voice,
          topic,
          kind,
          source,
          inspiration,
          attempt,
          {:empty_generation, other}
        )

      # A reasoning model that spent its turn thinking and never called the
      # tool. Transient, so it gets the same retry as an empty call rather
      # than costing the user a credit for nothing.
      {:error, {:no_tool_use, _} = reason} ->
        retry_or_fail(
          user,
          account,
          voice,
          topic,
          kind,
          source,
          inspiration,
          attempt,
          reason
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_or_fail(
         user,
         account,
         voice,
         topic,
         kind,
         source,
         inspiration,
         attempt,
         reason
       ) do
    if attempt < 2 do
      write(user, account, voice, topic, kind, source, inspiration, attempt + 1)
    else
      {:error, reason}
    end
  end

  defp reference_texts(source, inspiration) do
    corpus = if source, do: [source.text], else: []
    creator_posts = Enum.flat_map(inspiration, & &1.posts)

    corpus ++ creator_posts
  end

  defp derivative_from_any?(text, references) do
    Enum.any?(references, &derivative?(text, &1))
  end

  defp retry_without_references(user, account, voice, topic, kind, attempt) do
    if attempt < 2 do
      write(user, account, voice, topic, kind, nil, [], attempt + 1)
    else
      {:error, :derivative}
    end
  end

  defp store(user, account, kind, source, segments) do
    Content.create_generation(%{
      user_id: user.id,
      x_account_id: account.id,
      segments:
        Enum.map(
          segments,
          &%{"text" => &1 |> to_string() |> strip_thread_markers(), "media_ids" => []}
        ),
      kind: kind,
      source_corpus_post_id: source && source.id,
      source_likes: source && source.likes,
      model: AI.writer_model(),
      credits_cost: @credit_cost,
      score: source && source.engagement_score
    })
  end

  # Segments are chained into a thread by the publisher, so any numbering
  # the model writes itself publishes as literal text — a post that ends
  # "- a thread: 1/4". Instructing against it in the prompt is not a
  # guarantee, and the failure is visible to the user's followers, so the
  # markers come off here as well.
  #
  # Deliberately narrow. "3/4 of users never open it twice" is prose, so a
  # bare fraction is only treated as a counter when it is bracketed, has no
  # denominator ("1/"), or sits against a separator — which is how thread
  # numbering is actually written.
  @thread_markers [
    # Leading: "(1/4) ", "[1/4] ", "1/ ", "1/4 — "
    ~r/^\s*[\(\[]\d{1,2}\s*\/\s*\d{0,2}[\)\]]\s*/u,
    ~r/^\s*\d{1,2}\s*\/\s*(?=\D|$)/u,
    ~r/^\s*\d{1,2}\s*\/\s*\d{1,2}\s*[:.\-–—|]\s*/u,
    # Trailing: " (2/5)", " - 1/4", " 1/"
    ~r/\s*[\(\[]\d{1,2}\s*\/\s*\d{0,2}[\)\]]\s*$/u,
    ~r/\s*[:\-–—|]\s*\d{1,2}\s*\/\s*\d{0,2}\s*$/u,
    ~r/\s*\d{1,2}\s*\/\s*$/u,
    # " - a thread:" / " a thread"
    ~r/\s*[:\-–—|]*\s*\b(a\s+)?thread\s*:?\s*$/iu,
    ~r/\x{1F9F5}/u
  ]

  @doc false
  def strip_thread_markers(text) do
    @thread_markers
    |> Enum.reduce(text, &Regex.replace(&1, &2, ""))
    |> String.trim()
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

  # How much of the opening may coincide before it reads as a knock-off.
  # A shared run of six words anywhere is the obvious case, but the model
  # also likes to keep a distinctive opening and swap one noun — "the crux
  # of twitter is that…" becomes "the crux of life is that…", which shares
  # no six-word run and is still recognisably someone else's line.
  @opening_words 5
  @opening_allowed_matches 3

  @doc false
  def derivative?(text, source_text) do
    theirs = ngrams(source_text)

    Enum.any?(ngrams(text), &MapSet.member?(theirs, &1)) or
      opening_lifted?(text, source_text)
  end

  # Function words and the handful of nouns vague enough to behave like
  # them. An opening built only from these is English, not authorship:
  # "one of the things that" is shared by unrelated posts constantly.
  @common ~w(
    the a an of to in on at as by for from with about into over after
    is are was were be been being am do does did have has had can could
    will would should may might must
    i me my we our you your he she it its they them their this that these
    those there here what which who whom how why when where
    and or but if so than then not no all any every some most both each
    one two three first last next new old good best better
    thing things people way ways time times day days year years life
  )

  defp opening_lifted?(text, source_text) do
    mine = text |> words() |> Enum.take(@opening_words)
    theirs = source_text |> words() |> Enum.take(@opening_words)

    shared =
      mine
      |> Enum.zip(theirs)
      |> Enum.filter(fn {a, b} -> a == b end)
      |> Enum.map(&elem(&1, 0))

    length(mine) == @opening_words and
      length(shared) > @opening_allowed_matches and
      Enum.any?(shared, &(&1 not in @common))
  end

  defp ngrams(text) do
    text
    |> words()
    |> Enum.chunk_every(@ngram, 1, :discard)
    |> MapSet.new()
  end

  defp words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
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
