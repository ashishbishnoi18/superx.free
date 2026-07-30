defmodule SuperX.Workers.EmbedCorpus do
  @moduledoc """
  Backfills embeddings for corpus posts that don't have one.

  Runs in batches and re-enqueues itself while work remains, so a large
  backlog is drained without one job holding a queue slot for hours.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 3, unique: [period: 60]

  require Logger

  alias SuperX.AI
  alias SuperX.Content.Corpus
  alias SuperX.Content.CorpusPost

  @batch_size 64

  @impl Oban.Worker
  def perform(_job) do
    if AI.embeddings_configured?() do
      case Corpus.list_unembedded(@batch_size) do
        [] ->
          :ok

        posts ->
          embed_batch(posts)
          # More may remain; come back for the next batch.
          if length(posts) == @batch_size do
            %{} |> __MODULE__.new(schedule_in: 5) |> Oban.insert()
          end

          :ok
      end
    else
      :ok
    end
  end

  defp embed_batch(posts) do
    inputs = Enum.map(posts, &CorpusPost.embedding_input/1)

    case AI.embed(inputs, input_type: "document") do
      {:ok, vectors} when length(vectors) == length(posts) ->
        posts
        |> Enum.zip(vectors)
        |> Enum.each(fn {post, vector} -> Corpus.put_embedding(post, vector) end)

        Logger.info("Embedded #{length(posts)} corpus post(s)")

      {:ok, vectors} ->
        # A short response means the provider dropped inputs; pairing them
        # positionally would attach the wrong vector to the wrong post.
        Logger.warning(
          "Embedding returned #{length(vectors)} vectors for #{length(posts)} posts; skipping batch"
        )

      {:error, reason} ->
        Logger.warning("Embedding failed: #{inspect(reason)}")
    end
  end
end
