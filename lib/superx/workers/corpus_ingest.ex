defmodule SuperX.Workers.CorpusIngest do
  @moduledoc """
  Pulls high-performing posts into the shared corpus.

  Enqueued per topic so one bad query can't stall the rest, and so retries
  are scoped to the topic that actually failed.
  """

  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 3,
    # Two jobs for the same topic in the same hour would fetch the same
    # posts and cost rate limit for nothing.
    unique: [period: 3600, fields: [:worker, :args]]

  require Logger

  alias SuperX.Content.Corpus
  alias SuperX.Scraper

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"topic" => topic} = args}) do
    limit = args["limit"] || 50
    min_likes = args["min_likes"] || 500

    case Scraper.search(topic, limit: limit, min_likes: min_likes) do
      {:ok, []} ->
        Logger.info("Corpus ingest for #{inspect(topic)} returned nothing")
        :ok

      {:ok, posts} ->
        {count, _} = Corpus.upsert_many(posts)
        Logger.info("Ingested #{count} post(s) for #{inspect(topic)}")

        # Embeddings are backfilled separately so a slow embedding
        # provider doesn't hold the ingestion queue.
        if SuperX.AI.embeddings_configured?() do
          %{} |> SuperX.Workers.EmbedCorpus.new() |> Oban.insert()
        end

        :ok

      {:error, :scraper_not_running} ->
        Logger.info("Skipping corpus ingest: scraper worker unavailable")
        :ok

      {:error, reason} ->
        Logger.warning("Corpus ingest failed for #{inspect(topic)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Enqueues ingestion for a list of topics.

  Jobs are spaced out so a large topic list doesn't burst against X all
  at once — the scraper rate-limits internally, but queueing politely
  keeps the ingestion queue from being blocked for an hour.
  """
  def enqueue_topics(topics, opts \\ []) when is_list(topics) do
    spacing = opts[:spacing_seconds] || 90

    topics
    |> Enum.with_index()
    |> Enum.map(fn {topic, index} ->
      %{topic: topic, limit: opts[:limit] || 50, min_likes: opts[:min_likes] || 500}
      |> new(schedule_in: index * spacing)
    end)
    |> Oban.insert_all()
  end
end
