defmodule Mix.Tasks.Superx.Dev.Seed do
  @shortdoc "Seeds a demo user, corpus posts, and shelf items for local development"

  @moduledoc """
  Populates a local database with enough data to exercise every screen
  without X or LLM credentials.

      $ mix superx.dev.seed

  Prints a sign-in URL at the end. Refuses to run outside `:dev`.
  """

  use Mix.Task

  alias SuperX.Accounts.{Connect, User}
  alias SuperX.{Accounts, Analytics, Content, Repo}
  alias SuperX.Content.{Corpus, Post}

  @handle "demo_user"

  @impl true
  def run(_args) do
    unless Mix.env() == :dev do
      Mix.raise("mix superx.dev.seed only runs in the dev environment")
    end

    Mix.Task.run("app.start")

    {user, account} = ensure_user()
    seed_voice(account)
    seed_corpus()
    seed_shelf(user, account)
    seed_posts(user, account)
    seed_analytics(account)

    Mix.shell().info("""

    Seeded.

      User:    #{user.name} (@#{account.handle})
      Corpus:  #{Corpus.count()} posts
      Shelf:   #{Map.get(Content.shelf_counts(account), "all", 0)} drafts

    Sign in at:

      http://localhost:4000/dev/sign-in/#{user.id}
    """)
  end

  defp ensure_user do
    case Accounts.get_x_account_by_x_user_id("demo-1") do
      nil ->
        {:ok, user, account} =
          Connect.sign_in(
            %{
              x_user_id: "demo-1",
              handle: @handle,
              display_name: "Demo User",
              avatar_url: nil,
              description: "Building things and writing about it.",
              followers_count: 4210,
              following_count: 380,
              posts_count: 612
            },
            %{
              access_token: "demo-access-token",
              refresh_token: "demo-refresh-token",
              token_expires_at:
                DateTime.utc_now() |> DateTime.add(7200) |> DateTime.truncate(:second),
              scopes: ["tweet.read", "tweet.write", "users.read"]
            }
          )

        {user, account}

      account ->
        {Repo.get!(User, account.user_id), account}
    end
  end

  defp seed_voice(account) do
    {:ok, profile} = Content.get_or_create_voice_profile(account)

    Content.update_voice_profile(profile, %{
      about:
        "I build software and write about the parts that are harder than they look. I care about the gap between how a thing is supposed to work and how it actually works in production.",
      topics: "software engineering, startups, developer tools, writing, product design",
      style_notes:
        "Short declarative sentences. Lowercase openings sometimes. No emoji, no hashtags. Often opens with a concrete detail and ends on a claim rather than a question.",
      questions: [
        "What did I get wrong the first time I shipped this?",
        "Which tools actually earned their place in the stack?",
        "What does the failure mode look like at 3am?"
      ],
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @corpus [
    {"swyx",
     "The best engineers I know are aggressively boring in their tool choices and aggressively creative in their problem framing. Most people get this exactly backwards.",
     8400, 1200, 210, 92_000},
    {"patio11",
     "A thing nobody tells you about pricing: the number is not the product. The story you tell about the number is the product.",
     12_800, 2100, 340, 140_000},
    {"shreyas",
     "Strategy is a set of choices. If your strategy doesn't rule anything out, it isn't strategy, it's a list of things you like.",
     15_200, 3400, 280, 210_000},
    {"jasonfried",
     "We shipped a feature nobody asked for and removed one everybody used. Took us six months to admit which one was the mistake.",
     6700, 890, 410, 78_000},
    {"dhh",
     "Every abstraction you add is a bet that the thing underneath won't change. Most of those bets lose, and you pay the interest forever.",
     9300, 1600, 520, 105_000},
    {"levelsio",
     "Made $0 for 3 years. Then $100/mo. Then $1000/mo. The compounding is real but the first part is brutal and nobody posts about it.",
     22_000, 3900, 610, 340_000},
    {"eshear",
     "The hardest management lesson: the problem is almost never that people don't know what to do. It's that they don't believe it will matter.",
     11_400, 2300, 190, 130_000},
    {"rauchg",
     "Latency is a feature. Every 100ms you shave is a decision someone doesn't have to reconsider.",
     7800, 1400, 160, 88_000},
    {"amasad",
     "Hired for pedigree twice. Both times it went badly. Now I hire for whether someone has finished something hard on their own.",
     14_100, 2800, 470, 190_000},
    {"gergelyorosz",
     "Most 'we rewrote it in X and it's 10x faster' posts are really 'we finally understood the problem and rewrote it.' The language rarely mattered.",
     18_600, 4100, 380, 240_000}
  ]

  defp seed_corpus do
    now = DateTime.utc_now()

    posts =
      @corpus
      |> Enum.with_index()
      |> Enum.map(fn {{handle, text, likes, reposts, replies, impressions}, index} ->
        %{
          x_post_id: "seed-#{index}",
          author_handle: handle,
          author_name: handle,
          author_followers: 50_000 + index * 12_000,
          author_verified: true,
          text: text,
          lang: "en",
          likes: likes,
          reposts: reposts,
          replies: replies,
          impressions: impressions,
          bookmarks: div(likes, 6),
          posted_at:
            now |> DateTime.add(-(index + 1) * 18 * 3600, :second) |> DateTime.truncate(:second),
          topics: ["software engineering", "startups", "product design"],
          source: "seed"
        }
      end)

    Corpus.upsert_many(posts)
  end

  @shelf [
    "Spent the afternoon deleting code I wrote in March. Every line of it was reasonable at the time and none of it was load-bearing by June.",
    "The tooling question that actually matters isn't which framework. It's how long it takes a new person to get a failing test to pass.",
    "Most performance work is archaeology. You're not making it fast, you're finding the decision from two years ago that made it slow.",
    "Shipped something small today instead of planning something large. Third week running. The backlog looks worse and the product looks better.",
    "Nobody warns you that the hardest part of a rewrite is that the old thing keeps working well enough to make you doubt the whole project."
  ]

  defp seed_shelf(user, account) do
    corpus = Corpus.search(limit: 5, min_likes: 0)

    @shelf
    |> Enum.with_index()
    |> Enum.each(fn {text, index} ->
      source = Enum.at(corpus, rem(index, max(length(corpus), 1)))

      Content.create_generation(%{
        user_id: user.id,
        x_account_id: account.id,
        segments: [%{"text" => text, "media_ids" => []}],
        kind: "for_you",
        source_corpus_post_id: source && source.id,
        source_likes: source && source.likes,
        model: "seed",
        score: 1.0 - index * 0.05
      })
    end)
  end

  defp seed_posts(user, account) do
    now = DateTime.utc_now()

    # A couple of published posts so analytics and the streak render.
    Enum.each(0..5, fn offset ->
      Repo.insert!(%Post{
        user_id: user.id,
        x_account_id: account.id,
        status: "posted",
        segments: [%{"text" => "A post published #{offset + 1} day(s) ago.", "media_ids" => []}],
        published_at:
          now |> DateTime.add(-offset * 86_400, :second) |> DateTime.truncate(:second),
        x_post_ids: ["seed-post-#{offset}"],
        permalink: "https://x.com/i/status/seed-post-#{offset}",
        source: "manual",
        inserted_at: now |> DateTime.truncate(:second),
        updated_at: now |> DateTime.truncate(:second)
      })
    end)

    # One failure so the Failed tab has something to show.
    Repo.insert!(%Post{
      user_id: user.id,
      x_account_id: account.id,
      status: "failed",
      segments: [%{"text" => "This one hit a rate limit.", "media_ids" => []}],
      error: "X returned 429: too many requests",
      failed_at: now |> DateTime.add(-3600, :second) |> DateTime.truncate(:second),
      attempt_count: 3,
      source: "manual",
      inserted_at: now |> DateTime.truncate(:second),
      updated_at: now |> DateTime.truncate(:second)
    })
  end

  defp seed_analytics(account) do
    today = Date.utc_today()

    Enum.each(0..44, fn offset ->
      date = Date.add(today, -offset)

      Analytics.record_snapshot(account, date, %{
        followers: 4210 - offset * 18 + :erlang.phash2({account.id, offset}, 25),
        following: 380,
        posts: 612 - offset,
        impressions: 2400 + :erlang.phash2({:imp, offset}, 3200),
        engagements: 90 + :erlang.phash2({:eng, offset}, 140),
        likes: 70 + :erlang.phash2({:likes, offset}, 110),
        replies: 5 + :erlang.phash2({:rep, offset}, 18),
        reposts: 3 + :erlang.phash2({:rt, offset}, 12)
      })
    end)
  end
end
