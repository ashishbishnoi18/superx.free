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
    if embeddings_configured?() do
      case Corpus.list_unembedded(@batch_size) do
        [] ->
          :ok

        posts ->
          case embed_batch(posts) do
            :ok when length(posts) == @batch_size ->
              # Re-inserting this unique worker while its current job is
              # executing conflicts with itself and silently loses the next
              # batch. Snoozing reschedules this job after it releases the
              # execution lock.
              {:snooze, 5}

            :ok ->
              :ok

            {:error, reason} ->
              {:error, reason}
          end
      end
    else
      :ok
    end
  end

  defp embed_batch(posts) do
    inputs = Enum.map(posts, &CorpusPost.embedding_input/1)

    case embed(inputs) do
      {:ok, vectors} when length(vectors) == length(posts) ->
        result =
          posts
          |> Enum.zip(vectors)
          |> Enum.reduce_while(:ok, fn {post, vector}, :ok ->
            case Corpus.put_embedding(post, vector) do
              {:ok, _post} -> {:cont, :ok}
              {:error, changeset} -> {:halt, {:error, {:write_failed, changeset.errors}}}
            end
          end)

        if result == :ok, do: Logger.info("Embedded #{length(posts)} corpus post(s)")
        result

      {:ok, vectors} ->
        # A short response means the provider dropped inputs; pairing them
        # positionally would attach the wrong vector to the wrong post.
        Logger.warning(
          "Embedding returned #{length(vectors)} vectors for #{length(posts)} posts; skipping batch"
        )

        {:error, {:vector_count_mismatch, length(posts), length(vectors)}}

      {:error, reason} ->
        Logger.warning("Embedding failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # A narrow injection seam keeps provider failures deterministic in worker
  # tests. Production has no override and always calls SuperX.AI.
  defp embed(inputs) do
    case Application.get_env(:superx, __MODULE__, [])[:embed] do
      fun when is_function(fun, 2) -> fun.(inputs, input_type: "document")
      _ -> AI.embed(inputs, input_type: "document")
    end
  end

  defp embeddings_configured? do
    is_function(Application.get_env(:superx, __MODULE__, [])[:embed], 2) or
      AI.embeddings_configured?()
  end
end
