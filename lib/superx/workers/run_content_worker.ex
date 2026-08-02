defmodule SuperX.Workers.RunContentWorker do
  @moduledoc """
  Executes one configured content batch into the Ready to Post shelf.

  A batch is not retried as a whole: the writer already retries a failed
  model response and refunds its credit, while replaying a partly finished
  batch would create more drafts than the user requested and charge for
  them. Individual failed generations don't block the independent items
  after them, so a five-item batch still gets five chances to produce.
  """

  use Oban.Worker,
    queue: :generation,
    max_attempts: 1,
    unique: [period: 300, fields: [:worker, :args], states: :incomplete]

  import Ecto.Query

  require Logger

  alias SuperX.Content
  alias SuperX.Content.{Corpus, Post, VoiceProfile, Writer}
  alias SuperX.Repo
  alias SuperX.Workers
  alias SuperX.Workers.ContentWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"content_worker_id" => id}}) do
    case Workers.fetch_content_worker(id) do
      nil ->
        :ok

      worker ->
        case run(worker) do
          {:ok, _count} -> :ok
          {:error, reason, _count} -> {:error, reason}
        end
    end
  end

  @doc false
  def run(%ContentWorker{} = worker) do
    result = run_batch(worker)
    announce(worker, result)

    case result do
      {:ok, count} ->
        Logger.info("Worker #{worker.name} generated #{count} shelf item(s)")

      {:error, reason, count} ->
        Logger.warning(
          "Worker #{worker.name} delivered #{count} draft(s), then reported #{inspect(reason)}"
        )
    end

    result
  end

  @doc false
  def run_batch(%ContentWorker{} = worker) do
    worker = Repo.preload(worker, [:user, :x_account])
    {:ok, worker} = Workers.record_run_started(worker)

    1..worker.batch_size
    |> Enum.reduce_while({0, 0}, fn _index, {generated, failed} ->
      case generation_options(worker) do
        {:ok, opts} ->
          case Writer.generate(worker.user, worker.x_account, opts) do
            {:ok, _generation} ->
              {:cont, {generated + 1, failed}}

            {:error, :quota_exceeded, _details} ->
              {:halt, {:stopped, :quota_exceeded, generated}}

            {:error, reason} ->
              # Each item is independent, and Writer has already returned
              # this item's credit. Stopping here would turn one bad model
              # response into an unnecessarily short batch.
              Logger.warning(
                "Worker #{worker.name} skipped one generation and continued: #{inspect(reason)}"
              )

              {:cont, {generated, failed + 1}}
          end

        {:error, reason} ->
          # Missing source material is a batch-wide configuration problem;
          # retrying the identical lookup for every requested item can't help.
          {:halt, {:stopped, reason, generated}}
      end
    end)
    |> finish_batch()
  end

  defp finish_batch({generated, 0}), do: {:ok, generated}

  defp finish_batch({generated, failed}),
    do: {:error, {:generation_failed, failed}, generated}

  defp finish_batch({:stopped, reason, generated}), do: {:error, reason, generated}

  defp generation_options(%ContentWorker{topic_source: "products"} = worker) do
    {:ok, [topic: worker.product_context, kind: "products"]}
  end

  defp generation_options(%ContentWorker{topic_source: "voice"} = worker) do
    case own_post_topic(worker.x_account.id) || learned_topic(worker.x_account) do
      nil -> {:error, :no_topics}
      topic -> {:ok, [topic: topic, source: nil, kind: "for_you"]}
    end
  end

  defp generation_options(%ContentWorker{topic_source: "trends"} = worker) do
    voice = Content.get_voice_profile(worker.x_account)
    topics = voice && VoiceProfile.topic_list(voice)
    since = DateTime.utc_now() |> DateTime.add(-14, :day)

    # Relax in two steps, not one. Dropping only the date leaves an account
    # whose subjects match nothing in the library with no source at all —
    # which is every account whose topics are too vague to have been
    # ingested. Structure transfers across subjects, so any strong post
    # beats refusing to write, and this mirrors what the writer already
    # does when it picks a source itself.
    candidates =
      Enum.find_value(
        [
          [topics: topics, since: since],
          [topics: topics, since: nil],
          [topics: nil, since: nil]
        ],
        [],
        fn opts ->
          case Corpus.candidates_for(worker.x_account.id, opts[:topics],
                 limit: 10,
                 since: opts[:since]
               ) do
            [] -> nil
            posts -> posts
          end
        end
      )

    case candidates do
      [] ->
        {:error, :no_corpus_posts}

      posts ->
        source = Enum.random(posts)
        topic = List.first(source.topics) || source.text
        {:ok, [topic: topic, source: source, kind: "trending"]}
    end
  end

  # Locally published posts are the strongest seed because they capture an
  # idea the author actually chose to put their name on. On a fresh install
  # those rows may not exist yet, so the learned topics preserve the same
  # provenance: the voice profile was derived from the account's own posts.
  defp own_post_topic(x_account_id) do
    Post
    |> where([p], p.x_account_id == ^x_account_id and p.status == "posted")
    |> order_by(desc: :published_at)
    |> limit(20)
    |> Repo.all()
    |> case do
      [] -> nil
      posts -> posts |> Enum.random() |> Post.preview_text()
    end
  end

  defp learned_topic(account) do
    case Content.get_voice_profile(account) do
      nil -> nil
      voice -> voice |> VoiceProfile.topic_list() |> random_or_nil()
    end
  end

  defp random_or_nil([]), do: nil
  defp random_or_nil(values), do: Enum.random(values)

  defp announce(worker, result) do
    summary = result_summary(result, worker.batch_size)

    count = summary.generated

    if count > 0 do
      Phoenix.PubSub.broadcast(SuperX.PubSub, "shelf:#{worker.x_account_id}", :shelf_updated)
    end

    Phoenix.PubSub.broadcast(
      SuperX.PubSub,
      "workers:#{worker.x_account_id}",
      {:worker_finished, worker.id, summary}
    )
  end

  defp result_summary({:ok, generated}, requested) do
    %{status: :ok, generated: generated, failed: 0, requested: requested, reason: nil}
  end

  defp result_summary({:error, reason, generated}, requested) do
    %{
      status: :error,
      generated: generated,
      failed: requested - generated,
      requested: requested,
      reason: reason
    }
  end
end
