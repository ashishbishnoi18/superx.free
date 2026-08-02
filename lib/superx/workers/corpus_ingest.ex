defmodule SuperX.Workers.CorpusIngest do
  @moduledoc """
  Pulls high-performing posts into the shared corpus.

  Enqueued per topic so one bad query can't stall the rest, and so a retry
  is scoped to the topic that actually failed. The source clients own their
  rate limiting, so ready jobs can use all of the plan's available capacity.

  Reads come from twitterapi.io when it's configured, and fall back to the
  self-hosted Go worker otherwise. Both return the same shape, so nothing
  downstream knows or cares which one ran.
  """

  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 3,
    # Two jobs for the same topic in the same hour would fetch the same
    # posts and bill for them twice.
    unique: [period: 3600, fields: [:worker, :args]]

  require Logger

  alias SuperX.Content.Corpus
  alias SuperX.{Scraper, TwitterAPI}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"topic" => topic} = args}) do
    limit = args["limit"] || 40
    min_likes = args["min_likes"] || 500

    case fetch(topic, limit, min_likes) do
      {:ok, []} ->
        Logger.info("Corpus ingest for #{inspect(topic)} returned nothing")
        :ok

      {:ok, posts} ->
        {count, _} = Corpus.upsert_many(posts)
        Logger.info("Ingested #{count} post(s) for #{inspect(topic)}")

        # Embeddings are backfilled separately so a slow embedding provider
        # doesn't hold the ingestion queue.
        if SuperX.AI.embeddings_configured?() do
          %{} |> SuperX.Workers.EmbedCorpus.new() |> Oban.insert()
        end

        :ok

      {:error, :not_configured} ->
        Logger.info("Skipping corpus ingest: no read source configured")
        :ok

      {:error, :out_of_credits} ->
        # Retrying would only fail again and log noise; this needs a human
        # to top up.
        Logger.error("Corpus ingest halted: twitterapi.io is out of credits")
        :ok

      {:error, reason} ->
        Logger.warning("Corpus ingest failed for #{inspect(topic)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch(topic, limit, min_likes) do
    cond do
      TwitterAPI.configured?() ->
        case TwitterAPI.search(topic, min_likes: min_likes, max: limit, lang: "en") do
          {:ok, tweets} -> {:ok, tag(Enum.map(tweets, &TwitterAPI.to_corpus_attrs/1), topic)}
          error -> error
        end

      Scraper.configured?() ->
        case Scraper.search(topic, min_likes: min_likes, limit: limit) do
          {:ok, posts} -> {:ok, tag(posts, topic)}
          error -> error
        end

      true ->
        {:error, :not_configured}
    end
  end

  # The search query is the only signal we have for what a post is about,
  # and neither source returns topics of its own. Without this every post
  # lands with an empty topic array, `Corpus.candidates_for/3` can never
  # match a user's subjects, and the writer silently falls back to picking
  # any strong post at all.
  defp tag(posts, topic), do: Enum.map(posts, &Map.put(&1, :topics, [topic]))

  @doc """
  Enqueues ingestion for a list of topics.

  Jobs are ready immediately by default. `TwitterAPI` serialises calls at the
  configured plan rate and the scraper serialises its own token, so delaying
  the jobs here as well only applies an obsolete second throttle. Operators
  can still pass `:spacing_seconds` when a particular source requires it.
  """
  def enqueue_topics(topics, opts \\ []) when is_list(topics) do
    topics
    |> topic_jobs(opts)
    |> Oban.insert_all()
  end

  @doc false
  def topic_jobs(topics, opts \\ []) when is_list(topics) do
    spacing = opts[:spacing_seconds] || 0

    topics
    |> Enum.with_index()
    |> Enum.map(fn {topic, index} ->
      %{topic: topic, limit: opts[:limit] || 40, min_likes: opts[:min_likes] || 500}
      |> new(schedule_in: index * spacing)
    end)
  end
end
