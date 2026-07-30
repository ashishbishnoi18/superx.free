defmodule SuperX.Workers.CorpusRefresh do
  @moduledoc """
  Decides what the corpus should contain, then schedules the fetching.

  Topics come from what users actually write about — the union of every
  voice profile's topic list — so the library grows toward the accounts
  using it rather than toward a fixed editorial guess.

  Reads bill per record, so this caps how many topics run per day and
  spaces them out. The cap is deliberately low: an empty corpus is a
  visible problem the operator can fix, an unexpected invoice is not.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 2

  import Ecto.Query

  require Logger

  alias SuperX.Content.VoiceProfile
  alias SuperX.{Repo, TwitterAPI}
  alias SuperX.Workers.CorpusIngest

  # Topics per run. At ~40 posts each this is ~800 records a day, which is
  # a real but predictable spend.
  @topics_per_run 20

  @impl Oban.Worker
  def perform(_job) do
    cond do
      not TwitterAPI.configured?() ->
        Logger.info("Skipping corpus refresh: twitterapi.io not configured")
        :ok

      topics = active_topics() ->
        chosen = Enum.take(topics, @topics_per_run)

        if chosen == [] do
          Logger.info("Skipping corpus refresh: no voice profiles have topics yet")
        else
          CorpusIngest.enqueue_topics(chosen, limit: 40, min_likes: 500)

          Logger.info(
            "Queued corpus refresh for #{length(chosen)} topic(s)" <>
              if(length(topics) > @topics_per_run,
                do: " (#{length(topics) - @topics_per_run} deferred to tomorrow)",
                else: ""
              )
          )
        end

        :ok
    end
  end

  @doc """
  Distinct topics across all voice profiles, least-recently-fetched first
  so the tail of the list isn't starved by whatever sorts first.
  """
  def active_topics do
    VoiceProfile
    |> where([v], not is_nil(v.topics) and v.topics != "")
    |> select([v], v.topics)
    |> Repo.all()
    |> Enum.flat_map(&split_topics/1)
    |> Enum.frequencies()
    # Topics several users share are worth more than a single user's niche.
    |> Enum.sort_by(fn {_topic, count} -> -count end)
    |> Enum.map(&elem(&1, 0))
  end

  defp split_topics(topics) do
    topics
    |> String.split(~r/[,\n;]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.length(&1) < 3))
  end
end
