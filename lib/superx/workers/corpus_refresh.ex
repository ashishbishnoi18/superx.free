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

  # Topics per run, and posts fetched per topic.
  #
  # These are the nightly bill, not a throughput setting. The provider
  # charges per record — roughly 15 credits a post on search — so the
  # defaults below buy about 800 posts, near enough 12,000 credits, every
  # night. Divide your balance by that to get your runway in nights.
  #
  # They were originally sized for the free tier, where a call took eleven
  # seconds and the risk was a loop emptying the account before anyone
  # noticed. On a paid plan the pacing no longer binds and the only real
  # question is how fast you want to spend, which is the operator's call
  # rather than ours — hence the environment variables.
  @default_topics_per_run 20
  @default_posts_per_topic 40

  @doc "Topics fetched per nightly run."
  def topics_per_run do
    env_int("SUPERX_CORPUS_TOPICS_PER_RUN", @default_topics_per_run)
  end

  @doc "Posts fetched per topic. Multiply by `topics_per_run/0` for the bill."
  def posts_per_topic do
    env_int("SUPERX_CORPUS_POSTS_PER_TOPIC", @default_posts_per_topic)
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end

  # How much of a run users' own subjects may claim. The remainder goes to
  # the seed set, so the library keeps broadening instead of narrowing to
  # whatever the current handful of accounts happen to write about.
  @user_topics_per_run 12

  # What the library is seeded with. A corpus that only fetches topics
  # someone already asked for is empty on day one and stays narrow after
  # that — and the writer borrows *structure*, which transfers across
  # subjects, so breadth here is worth more than precision.
  #
  # The first seven are the categories SuperX itself suggests, which is a
  # useful prior on what this audience actually writes about. The rest
  # widen it past what one competitor chose to feature.
  @seed_topics [
    "AI coding tips",
    "marketing strategies",
    "startup advice",
    "productivity hacks",
    "design inspiration",
    "growth tactics",
    "tech trends",
    "building in public",
    "indie hacking",
    "startup lessons",
    "bootstrapping a business",
    "SaaS growth",
    "AI agents",
    "LLM applications",
    "developer tools",
    "software engineering career",
    "engineering leadership",
    "product design",
    "marketing strategy",
    "content marketing",
    "personal branding",
    "writing online",
    "productivity systems",
    "remote work",
    "fundraising advice",
    "growth experiments",
    "customer research"
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if TwitterAPI.configured?() do
      chosen = topics_for_run(args["limit_topics"] || topics_per_run())

      CorpusIngest.enqueue_topics(chosen,
        limit: args["limit"] || posts_per_topic(),
        min_likes: args["min_likes"] || 500,
        spacing_seconds: args["spacing_seconds"] || 120
      )

      Logger.info("Queued corpus refresh for #{length(chosen)} topic(s)")
    else
      Logger.info("Skipping corpus refresh: twitterapi.io not configured")
    end

    :ok
  end

  @doc """
  The topics one run should fetch: users' own subjects first, then as much
  of the seed set as there is room for.

  The seed set is rotated by day so a run that only has room for a few of
  them still covers the whole list over time, rather than re-fetching the
  same head every night.
  """
  def topics_for_run(count \\ nil) do
    count = count || topics_per_run()
    user_topics = Enum.take(active_topics(), min(@user_topics_per_run, count))

    (user_topics ++ rotated_seeds())
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(count)
  end

  defp rotated_seeds do
    offset = rem(Date.day_of_year(Date.utc_today()), length(@seed_topics))
    Enum.drop(@seed_topics, offset) ++ Enum.take(@seed_topics, offset)
  end

  @doc "The built-in topic list, for tests and operator tooling."
  def seed_topics, do: @seed_topics

  @doc """
  Distinct topics across all voice profiles, most widely shared first.

  Topics too vague to name a subject are dropped — see `specific?/1`.
  """
  def active_topics do
    VoiceProfile
    |> where([v], not is_nil(v.topics) and v.topics != "")
    |> select([v], v.topics)
    |> Repo.all()
    |> Enum.flat_map(&split_topics/1)
    |> Enum.filter(&specific?/1)
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

  # Words that describe a posture rather than a subject.
  @vague ~w(
    life thoughts thought opinions opinion observations observation
    everyday daily musings random stuff things thing ideas idea
    updates personal my me general misc various
  )

  @doc """
  Whether a topic is worth searching the corpus for.

  "personal thoughts" and "life" are honest descriptions of what someone
  writes about, but as *queries* they return whatever went viral that day
  — breaking news, politics, sport — none of which has a shape worth
  borrowing. A topic has to contain at least one word that names an actual
  subject.

  Nobody loses sources by this: the writer already falls back to any
  strong post when a user's topics match nothing, so these accounts draw
  on the curated seed set instead of the day's news cycle.
  """
  def specific?(topic) do
    topic
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.any?(&(&1 not in @vague))
  end
end
