defmodule SuperX.Workers.RunContentWorker do
  @moduledoc """
  Executes one configured content batch into the Ready to Post shelf.

  A batch is not retried as a whole: the writer already retries a failed
  model response and refunds its credit, while replaying a partly finished
  batch would create more drafts than the user requested and charge for
  them. The next manual or scheduled run is the safe retry boundary.
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
        case run_batch(worker) do
          {:ok, count} ->
            announce(worker, count)
            :ok

          {:error, reason, count} ->
            announce(worker, count)

            Logger.warning(
              "Worker #{worker.name} stopped after #{count} draft(s): #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  @doc false
  def run_batch(%ContentWorker{} = worker) do
    worker = Repo.preload(worker, [:user, :x_account])
    {:ok, worker} = Workers.record_run_started(worker)

    Enum.reduce_while(1..worker.batch_size, {:ok, 0}, fn _index, {:ok, count} ->
      with {:ok, opts} <- generation_options(worker),
           {:ok, _generation} <- Writer.generate(worker.user, worker.x_account, opts) do
        {:cont, {:ok, count + 1}}
      else
        {:error, :quota_exceeded, _details} -> {:halt, {:ok, count}}
        {:error, reason} -> {:halt, {:error, reason, count}}
      end
    end)
  end

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

  defp announce(worker, count) do
    if count > 0 do
      Logger.info("Worker #{worker.name} generated #{count} shelf item(s)")
      Phoenix.PubSub.broadcast(SuperX.PubSub, "shelf:#{worker.x_account_id}", :shelf_updated)
    end

    Phoenix.PubSub.broadcast(
      SuperX.PubSub,
      "workers:#{worker.x_account_id}",
      {:worker_finished, worker.id, count}
    )
  end
end
