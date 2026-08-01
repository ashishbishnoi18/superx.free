defmodule SuperX.Content.Corpus do
  @moduledoc """
  The shared library of high-performing posts: ingestion and retrieval.

  Search is hybrid. Full-text handles exact terms and is always available;
  vector similarity handles "posts *about* this" and only runs when
  embeddings are configured. Results are then re-ranked by engagement, so
  a weak match on a post that did nothing never outranks a good match on
  a post that worked.
  """

  import Ecto.Query
  import Pgvector.Ecto.Query

  alias SuperX.AI
  alias SuperX.Content.{CorpusOutlierBaseline, CorpusPost, Exclusions}
  alias SuperX.Repo

  @doc """
  Inserts or updates a batch of scraped posts.

  Metrics are refreshed on conflict because a post ingested an hour after
  publication will have grown since.
  """
  def upsert_many(attrs_list) when is_list(attrs_list) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      attrs_list
      |> Enum.map(&build_row(&1, now))
      |> Enum.reject(&is_nil/1)

    case rows do
      [] ->
        {0, nil}

      rows ->
        {:ok, result} =
          Repo.transaction(fn ->
            # Ingestion jobs can overlap. Serialising this short write path
            # prevents a later transaction from publishing a median that
            # was calculated before an earlier batch committed.
            Repo.query!(
              "SELECT pg_advisory_xact_lock(hashtext('superx.corpus.outlier_baselines'))"
            )

            old_buckets = existing_buckets(rows)

            {count, returned} =
              Repo.insert_all(CorpusPost, rows,
                on_conflict: refresh_query(),
                conflict_target: [:x_post_id],
                returning: [:follower_bucket]
              )

            new_buckets = Enum.map(returned, & &1.follower_bucket)
            refresh_outlier_baselines(old_buckets ++ new_buckets)

            {count, nil}
          end)

        result
    end
  end

  defp existing_buckets(rows) do
    x_post_ids = Enum.map(rows, & &1.x_post_id)

    CorpusPost
    |> where([c], c.x_post_id in ^x_post_ids)
    |> select([c], c.follower_bucket)
    |> Repo.all()
  end

  # Fixed half-decade bands compare accounts no more than roughly 3.2x
  # apart, while leaving enough observations for a stable median. The
  # sub-1,000 tail is pooled because the corpus is sparse there and the
  # underlying engagement score already floors reach at 100 followers.
  #
  # The median, rather than the mean, defines "typical": the very viral
  # posts this corpus collects must not drag their own benchmark upwards.
  # Comparing the existing weighted engagement score within reach bands
  # also avoids the permanent small-account premium produced by a flat
  # engagement/followers ratio. A multiple of 1.0 is therefore the middle
  # post for a genuinely comparable account size.
  defp refresh_outlier_baselines(buckets) do
    buckets = Enum.uniq(buckets)

    if buckets != [] do
      Repo.query!(
        """
        INSERT INTO corpus_outlier_baselines AS baseline
          (follower_bucket, median_engagement_score, sample_size)
        SELECT
          follower_bucket,
          percentile_cont(0.5) WITHIN GROUP (ORDER BY engagement_score),
          count(*)
        FROM corpus_posts
        WHERE follower_bucket = ANY($1::smallint[])
        GROUP BY follower_bucket
        ON CONFLICT (follower_bucket) DO UPDATE SET
          median_engagement_score = EXCLUDED.median_engagement_score,
          sample_size = EXCLUDED.sample_size
        """,
        [buckets]
      )
    end
  end

  # Topics are unioned rather than replaced: the same post surfacing under
  # two searches is genuinely about both, and replacing would let whichever
  # ingest ran last decide what the post is about.
  defp refresh_query do
    from(c in CorpusPost,
      update: [
        set: [
          likes: fragment("EXCLUDED.likes"),
          reposts: fragment("EXCLUDED.reposts"),
          replies: fragment("EXCLUDED.replies"),
          quotes: fragment("EXCLUDED.quotes"),
          bookmarks: fragment("EXCLUDED.bookmarks"),
          impressions: fragment("EXCLUDED.impressions"),
          engagement_score: fragment("EXCLUDED.engagement_score"),
          author_followers: fragment("EXCLUDED.author_followers"),
          updated_at: fragment("EXCLUDED.updated_at"),
          topics:
            fragment(
              "ARRAY(SELECT DISTINCT unnest(COALESCE(?, ARRAY[]::varchar[]) || COALESCE(EXCLUDED.topics, ARRAY[]::varchar[])))",
              c.topics
            )
        ]
      ]
    )
  end

  # Runs each row through the changeset so engagement scoring and
  # validation stay in one place, then flattens it for insert_all.
  defp build_row(attrs, now) do
    case CorpusPost.changeset(%CorpusPost{}, attrs) do
      %{valid?: true} = changeset ->
        changeset
        |> Ecto.Changeset.apply_changes()
        |> Map.take([
          :x_post_id,
          :author_handle,
          :author_name,
          :author_avatar_url,
          :author_followers,
          :author_verified,
          :text,
          :lang,
          :likes,
          :reposts,
          :replies,
          :quotes,
          :bookmarks,
          :impressions,
          :engagement_score,
          :posted_at,
          :media,
          :has_media,
          :is_thread,
          :topics,
          :embedding,
          :source,
          :ingested_at
        ])
        |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})

      invalid ->
        require Logger
        Logger.debug("Skipping corpus post: #{inspect(invalid.errors)}")
        nil
    end
  end

  @doc """
  Searches the corpus.

  Options:

    * `:query` — free text
    * `:topics` — restrict to posts tagged with any of these
    * `:min_likes` — engagement floor (default 100)
    * `:since` — only posts published after this datetime
    * `:has_media` — true/false
    * `:sort` — `:engagement` (default) or `:outlier`
    * `:limit` — default 40
  """
  def search(opts \\ []) do
    limit = opts[:limit] || 40
    query_text = opts[:query]
    sort = normalize_sort(opts[:sort])

    base =
      CorpusPost
      |> filter_min_likes(opts[:min_likes] || 100)
      |> filter_since(opts[:since])
      |> filter_topics(opts[:topics])
      |> filter_media(opts[:has_media])
      |> filter_exclusions(opts[:exclude])

    cond do
      is_nil(query_text) or query_text == "" ->
        base
        |> with_outlier()
        |> order_results(sort)
        |> limit(^limit)
        |> Repo.all()

      AI.embeddings_configured?() ->
        semantic_search(base, query_text, limit, sort)

      true ->
        text_search(base, query_text, limit, sort)
    end
  end

  defp normalize_sort(sort) when sort in [:outlier, "outlier"], do: :outlier
  defp normalize_sort(_sort), do: :engagement

  defp text_search(base, query_text, limit, :outlier) do
    base
    |> where([c], fragment("? @@ plainto_tsquery('english', ?)", c.search, ^query_text))
    |> with_outlier()
    |> order_results(:outlier)
    |> limit(^limit)
    |> Repo.all()
  end

  defp text_search(base, query_text, limit, :engagement) do
    base
    |> where([c], fragment("? @@ plainto_tsquery('english', ?)", c.search, ^query_text))
    |> with_outlier()
    |> order_by([c],
      desc:
        fragment(
          # Blend textual relevance with how well the post actually did.
          "ts_rank(?, plainto_tsquery('english', ?)) * log(greatest(?, 2))",
          c.search,
          ^query_text,
          c.engagement_score
        )
    )
    |> limit(^limit)
    |> Repo.all()
  end

  defp semantic_search(base, query_text, limit, sort) do
    case AI.embed_one(query_text, input_type: "query") do
      {:ok, vector} ->
        # Over-fetch on distance, then re-rank by engagement, so the final
        # set is both on-topic and proven.
        nearest =
          base
          |> where([c], not is_nil(c.embedding))
          |> order_by([c], asc: cosine_distance(c.embedding, ^Pgvector.new(vector)))
          |> limit(^(limit * 3))
          |> select([c], c.id)

        CorpusPost
        |> where([c], c.id in subquery(nearest))
        |> with_outlier()
        |> order_results(sort)
        |> limit(^limit)
        |> Repo.all()

      {:error, _reason} ->
        text_search(base, query_text, limit, sort)
    end
  end

  # A median is only worth dividing by once enough posts stand behind it.
  # The sparse tail of the corpus is the small-account bands, which is
  # exactly where one viral post would otherwise be scored against a
  # handful of neighbours and reported as "12x" — an artefact of the
  # sample, not a fact about the post.
  #
  # Below this the score is suppressed to 1.0 rather than estimated from
  # a global median: engagement rate varies so much with account size
  # that a corpus-wide baseline would systematically mislabel exactly the
  # accounts it was standing in for. "We cannot tell yet" is the honest
  # answer, and the badge only renders above 2x anyway.
  @default_min_baseline_sample 30

  @doc false
  # Configurable so tests can exercise the maths on small fixtures without
  # having to manufacture a statistically meaningful corpus to do it.
  def min_baseline_sample do
    Application.get_env(:superx, :min_outlier_baseline_sample, @default_min_baseline_sample)
  end

  defmacrop outlier_multiple(post, baseline) do
    quote do
      fragment(
        "CASE WHEN COALESCE(?, 0) >= ? THEN COALESCE(? / NULLIF(?, 0.0), 1.0) ELSE 1.0 END",
        unquote(baseline).sample_size,
        ^min_baseline_sample(),
        unquote(post).engagement_score,
        unquote(baseline).median_engagement_score
      )
    end
  end

  defp with_outlier(query) do
    query
    |> join(:left, [c], baseline in CorpusOutlierBaseline,
      as: :outlier_baseline,
      on: baseline.follower_bucket == c.follower_bucket
    )
    |> select_merge(
      [c, outlier_baseline: baseline],
      %{outlier_score: type(outlier_multiple(c, baseline), :float)}
    )
  end

  defp order_results(query, :outlier) do
    order_by(query, [c, outlier_baseline: baseline],
      desc: outlier_multiple(c, baseline),
      desc: c.engagement_score
    )
  end

  defp order_results(query, :engagement), do: order_by(query, [c], desc: c.engagement_score)

  defp filter_min_likes(query, nil), do: query
  defp filter_min_likes(query, min), do: where(query, [c], c.likes >= ^min)

  defp filter_since(query, nil), do: query
  defp filter_since(query, since), do: where(query, [c], c.posted_at >= ^since)

  defp filter_topics(query, nil), do: query
  defp filter_topics(query, []), do: query
  defp filter_topics(query, topics), do: where(query, [c], fragment("? && ?", c.topics, ^topics))

  defp filter_media(query, nil), do: query
  defp filter_media(query, value), do: where(query, [c], c.has_media == ^value)

  # The pattern is bound as a parameter rather than spliced into the SQL,
  # so the category definitions stay plain regex with nothing to escape.
  defp filter_exclusions(query, keys) do
    case Exclusions.pattern_for(keys) do
      nil -> query
      pattern -> where(query, [c], fragment("? !~* ?", c.text, ^pattern))
    end
  end

  @doc """
  Picks candidate posts to use as structural templates for a user.

  Excludes anything already used as a source for this account, so the
  shelf doesn't keep rebuilding the same post. `:min_outlier` opts into a
  corpus-relative performance floor; omitting it preserves the existing
  selection behaviour.
  """
  def candidates_for(x_account_id, topics, opts \\ []) do
    limit = opts[:limit] || 10

    used =
      from(g in SuperX.Content.Generation,
        where: g.x_account_id == ^x_account_id and not is_nil(g.source_corpus_post_id),
        select: g.source_corpus_post_id
      )

    CorpusPost
    |> where([c], c.likes >= ^(opts[:min_likes] || 500))
    |> where([c], c.id not in subquery(used))
    |> usable_as_template()
    # Unconditional here, unlike on Inspiration: someone researching crypto
    # posts wants to see them, but nobody wants the overnight shelf quietly
    # handing them the shape of a political rant to publish.
    |> filter_exclusions(Exclusions.all_keys())
    |> filter_topics(topics)
    |> filter_since(opts[:since])
    |> filter_min_outlier(opts[:min_outlier])
    # Randomised among the strong candidates so two runs don't produce
    # the same shelf.
    |> order_by([c], desc: c.engagement_score)
    |> limit(^(limit * 5))
    |> subquery()
    |> order_by(fragment("random()"))
    |> limit(^limit)
    |> Repo.all()
  end

  defp filter_min_outlier(query, nil), do: query

  # Same sample floor as the displayed multiple: a band too thin to score
  # is too thin to filter on, and an inner join here would otherwise let
  # a noisy median decide what the writer is allowed to borrow from.
  defp filter_min_outlier(query, minimum) do
    query
    |> join(:inner, [c], baseline in CorpusOutlierBaseline,
      on: baseline.follower_bucket == c.follower_bucket
    )
    |> where([c, baseline], baseline.sample_size >= ^min_baseline_sample())
    |> where(
      [c, baseline],
      c.engagement_score >= baseline.median_engagement_score * ^minimum
    )
  end

  # Not every post that performed well is worth learning from. A ranked
  # list of statistics, a link dump, or a one-line joke all earn enormous
  # engagement and none of them carry a shape that transfers to another
  # subject — the writer imitates their cadence and produces nonsense.
  #
  # These are cheap structural proxies rather than a classifier pass: the
  # cost of a false negative is one fewer candidate, and there are
  # millions.
  # `?` cannot appear inside a fragment's SQL — Ecto reads it as a
  # parameter placeholder — so the patterns spell out alternations that
  # would normally use it.
  defp usable_as_template(query) do
    query
    # Too short to have a structure worth borrowing.
    |> where([c], fragment("length(?) >= 120", c.text))
    # Opens with a link, so the post isn't doing the work.
    |> where([c], fragment("? !~* '^[[:space:]]*(http|https)://'", c.text))
    # Heavily broken into lines: the shape is a list, not an argument.
    |> where([c], fragment("(length(?) - length(replace(?, E'\\n', ''))) < 6", c.text, c.text))
    # Opens with "1." or "1)" — a ranked list, same problem.
    |> where([c], fragment("? !~ '^[[:space:]]*[0-9]+[.)][[:space:]]'", c.text))
    # A news alert. These travel enormously and their shape is the event,
    # not the writing, so imitating one produces a draft announcing
    # nothing.
    #
    # Case-sensitive and anchored to the start of a line, because the
    # marker is shouted and leads: matching "breaking" anywhere would
    # throw away a post about breaking a paragraph in two. The `(?m)`
    # flag isn't available here — Ecto reads `?` as a placeholder — so
    # the newline is spelled out instead.
    |> where([c], fragment("? !~ E'(^|\\n)[[:space:]]*(BREAKING|JUST IN|DEVELOPING)'", c.text))
    # Promises a list: "3 types of…", "10 lessons…". The corpus stores a
    # thread's opening post, and the list itself lives in replies that were
    # never captured — so the shape on offer is a hook with no payload, and
    # borrowing it produces a draft that sets something up and stops.
    |> where(
      [c],
      fragment(
        "? !~* '[0-9]+[[:space:]]+(types|ways|things|lessons|reasons|rules|steps|tips|mistakes|habits|signs|traits|truths|questions)'",
        c.text
      )
    )
  end

  @doc "Posts still missing an embedding, for the backfill job."
  def list_unembedded(limit \\ 100) do
    CorpusPost
    |> where([c], is_nil(c.embedding))
    |> order_by(desc: :engagement_score)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Writes an embedding onto a corpus post."
  def put_embedding(%CorpusPost{} = post, vector) do
    post
    |> Ecto.Changeset.change(embedding: Pgvector.new(vector))
    |> Repo.update()
  end

  @doc "Total posts in the library."
  def count, do: Repo.aggregate(CorpusPost, :count)

  @doc "Distinct topic tags with counts, for the filter chips."
  def topic_facets(limit \\ 24) do
    from(c in CorpusPost,
      select: {fragment("unnest(?)", c.topics), count()},
      group_by: fragment("1"),
      order_by: [desc: count()],
      limit: ^limit
    )
    |> Repo.all()
  end
end
