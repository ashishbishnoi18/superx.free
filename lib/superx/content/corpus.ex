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
  alias SuperX.Content.CorpusPost
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

    Repo.insert_all(CorpusPost, rows,
      on_conflict: refresh_query(),
      conflict_target: [:x_post_id]
    )
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
    * `:limit` — default 40
  """
  def search(opts \\ []) do
    limit = opts[:limit] || 40
    query_text = opts[:query]

    base =
      CorpusPost
      |> filter_min_likes(opts[:min_likes] || 100)
      |> filter_since(opts[:since])
      |> filter_topics(opts[:topics])
      |> filter_media(opts[:has_media])

    cond do
      is_nil(query_text) or query_text == "" ->
        base
        |> order_by([c], desc: c.engagement_score)
        |> limit(^limit)
        |> Repo.all()

      AI.embeddings_configured?() ->
        semantic_search(base, query_text, limit)

      true ->
        text_search(base, query_text, limit)
    end
  end

  defp text_search(base, query_text, limit) do
    base
    |> where([c], fragment("? @@ plainto_tsquery('english', ?)", c.search, ^query_text))
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

  defp semantic_search(base, query_text, limit) do
    case AI.embed_one(query_text, input_type: "query") do
      {:ok, vector} ->
        # Over-fetch on distance, then re-rank by engagement, so the final
        # set is both on-topic and proven.
        base
        |> where([c], not is_nil(c.embedding))
        |> order_by([c], asc: cosine_distance(c.embedding, ^Pgvector.new(vector)))
        |> limit(^(limit * 3))
        |> subquery()
        |> order_by([c], desc: c.engagement_score)
        |> limit(^limit)
        |> Repo.all()

      {:error, _reason} ->
        text_search(base, query_text, limit)
    end
  end

  defp filter_min_likes(query, nil), do: query
  defp filter_min_likes(query, min), do: where(query, [c], c.likes >= ^min)

  defp filter_since(query, nil), do: query
  defp filter_since(query, since), do: where(query, [c], c.posted_at >= ^since)

  defp filter_topics(query, nil), do: query
  defp filter_topics(query, []), do: query
  defp filter_topics(query, topics), do: where(query, [c], fragment("? && ?", c.topics, ^topics))

  defp filter_media(query, nil), do: query
  defp filter_media(query, value), do: where(query, [c], c.has_media == ^value)

  @doc """
  Picks candidate posts to use as structural templates for a user.

  Excludes anything already used as a source for this account, so the
  shelf doesn't keep rebuilding the same post.
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
    |> filter_topics(topics)
    |> filter_since(opts[:since])
    # Randomised among the strong candidates so two runs don't produce
    # the same shelf.
    |> order_by([c], desc: c.engagement_score)
    |> limit(^(limit * 5))
    |> subquery()
    |> order_by(fragment("random()"))
    |> limit(^limit)
    |> Repo.all()
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
