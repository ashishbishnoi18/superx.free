defmodule SuperX.Signals.Scout do
  @moduledoc """
  Runs one watch: fetch candidates, score them against the agent's ICP,
  keep what clears the bar.

  Scoring is one batched LLM call per run rather than one per person. At a
  few hundred candidates a day the per-person version would dominate both
  latency and cost, and the model judges a batch about as well.
  """

  require Logger

  alias SuperX.{AI, Signals, TwitterAPI}
  alias SuperX.Signals.Agent

  # Per run, per agent. The plan's leads/day cap is enforced above this;
  # this is the ceiling on what one pass costs.
  @candidates_per_run 40

  @doc "Runs an agent and returns how many leads it kept."
  @spec run(Agent.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(%Agent{} = agent, opts \\ []) do
    account = agent.x_account
    max_new_leads = Keyword.get(opts, :max_new_leads, @candidates_per_run)

    with {:ok, candidates} <- fetch(agent),
         candidates <- prepare_candidates(candidates),
         {known, candidates} <- split_known(candidates, account),
         _filed <- Signals.file_known_leads(agent, known),
         {:ok, scored} <- score(agent, candidates) do
      kept =
        scored
        |> Enum.filter(&((&1[:score] || 0) >= agent.min_score))
        # When today's quota has only a few slots left, a person expects the
        # strongest matches to consume them rather than provider response order.
        |> Enum.sort_by(&(&1[:score] || 0), :desc)
        |> Enum.take(max_new_leads)
        |> Enum.map(&Map.merge(&1, %{x_account_id: account.id, signal_agent_id: agent.id}))

      {count, _} = Signals.upsert_leads(kept)
      {:ok, count}
    end
  end

  # --- Fetching ------------------------------------------------------------

  defp fetch(%Agent{kind: "follower", target: handle}) do
    case TwitterAPI.followers(handle, max: @candidates_per_run) do
      {:ok, users} -> {:ok, Enum.map(users, &from_user/1)}
      error -> error
    end
  end

  defp fetch(%Agent{kind: "profile", target: handle}) do
    # People replying to an account are engaging with it, which is a
    # stronger signal than following it.
    case TwitterAPI.user_tweets(handle, max: 5) do
      {:ok, tweets} ->
        results =
          tweets
          |> Enum.take(3)
          |> Enum.map(&TwitterAPI.replies(&1["id"], max: 15))

        case Enum.split_with(results, &match?({:ok, _replies}, &1)) do
          {[], [error | _]} ->
            error

          {successful, _errors} ->
            successful
            |> Enum.flat_map(fn {:ok, replies} -> replies end)
            |> Enum.map(&from_tweet/1)
            |> then(&{:ok, &1})
        end

      error ->
        error
    end
  end

  defp fetch(%Agent{kind: "list", target: list_id}) do
    case TwitterAPI.list_timeline(list_id, max: @candidates_per_run) do
      {:ok, tweets} -> {:ok, Enum.map(tweets, &from_tweet/1)}
      error -> error
    end
  end

  defp fetch(%Agent{kind: "keyword", target: query}) do
    case TwitterAPI.search(query, max: @candidates_per_run, type: "Latest", min_likes: 0) do
      {:ok, tweets} -> {:ok, Enum.map(tweets, &from_tweet/1)}
      error -> error
    end
  end

  defp from_user(user) do
    %{
      x_user_id: user[:x_user_id],
      handle: user[:handle],
      display_name: user[:display_name],
      avatar_url: user[:avatar_url],
      bio: user[:description],
      location: user[:location],
      followers_count: user[:followers_count] || 0,
      following_count: user[:following_count] || 0,
      verified: user[:verified] || false
    }
  end

  defp from_tweet(tweet) do
    author = tweet["author"] || %{}

    %{
      x_user_id: author["id"],
      handle: author["userName"],
      display_name: author["name"],
      avatar_url: author["profilePicture"],
      bio: author["description"],
      location: author["location"],
      followers_count: author["followers"] || 0,
      following_count: author["following"] || 0,
      verified: author["isBlueVerified"] || false,
      source_post_id: tweet["id"],
      source_post_text: tweet["text"]
    }
  end

  defp prepare_candidates(candidates) do
    candidates
    |> Enum.reject(&is_nil(&1[:handle]))
    |> Enum.uniq_by(&String.downcase(&1[:handle]))
  end

  # Existing people still need filing in this agent's destination, but they
  # do not need another model call and their qualification should not change.
  defp split_known(candidates, account) do
    known = Signals.known_handles(account)

    Enum.split_with(candidates, fn candidate ->
      MapSet.member?(known, String.downcase(candidate[:handle]))
    end)
  end

  # --- Scoring -------------------------------------------------------------

  defp score(_agent, []), do: {:ok, []}

  defp score(%Agent{ideal_customer: icp} = agent, candidates)
       when is_binary(icp) and icp != "" do
    if AI.configured?() do
      do_score(agent, candidates)
    else
      # Keep discoveries useful without pretending a placeholder is a model
      # judgement. The floor lets them pass the agent's filter; the persisted
      # reason keeps that compromise visible in Contacts and exports.
      fallback_score(agent, candidates, "Not AI-scored: no LLM is configured.")
    end
  end

  defp score(agent, candidates) do
    fallback_score(agent, candidates, "Not AI-scored: this agent has no match description.")
  end

  defp fallback_score(agent, candidates, reason) do
    {:ok, Enum.map(candidates, &Map.merge(&1, %{score: agent.min_score, reason: reason}))}
  end

  defp do_score(agent, candidates) do
    listed =
      candidates
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {c, i} ->
        """
        #{i}. @#{c[:handle]} — #{c[:display_name]} (#{c[:followers_count]} followers)
        bio: #{String.slice(c[:bio] || "", 0, 200)}
        #{if c[:source_post_text], do: "posted: " <> String.slice(c[:source_post_text], 0, 200), else: ""}
        """
      end)

    prompt = """
    You are qualifying leads for this person:

    <looking_for>
    #{agent.ideal_customer}
    </looking_for>

    <candidates>
    #{listed}
    </candidates>

    Score each 0-100 for how well they match. Judge on evidence in the bio
    and post, not on follower count — a small account that clearly fits is
    a better lead than a large one that doesn't.

    Score low for: bots, engagement farms, accounts with no bio, people who
    are obviously selling the same thing, and anyone matching only on a
    coincidental keyword.

    Give a one-sentence reason for anything above #{agent.min_score}.
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
           max_tokens: 2000,
           thinking: false,
           tool_description: "Score every candidate."
         ) do
      {:ok, %{"scores" => scores}} ->
        by_index = Map.new(scores, &{&1["index"], &1})

        {:ok,
         candidates
         |> Enum.with_index(1)
         |> Enum.map(fn {c, i} ->
           case by_index[i] do
             %{"score" => s} = entry ->
               Map.merge(c, %{score: clamp(s), reason: entry["reason"]})

             _ ->
               Map.merge(c, %{score: 0, reason: nil})
           end
         end)}

      {:error, reason} ->
        Logger.warning("Lead scoring failed for agent #{agent.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp clamp(n) when is_integer(n), do: n |> max(0) |> min(100)
  defp clamp(_), do: 0
end
