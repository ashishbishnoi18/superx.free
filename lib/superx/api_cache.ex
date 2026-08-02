defmodule SuperX.ApiCache do
  @moduledoc """
  Persistent cache for paid upstream reads.

  twitterapi.io bills per record returned, so an identical call made
  twice costs twice. This sits in front of the client and answers from
  storage when we have already bought the same thing recently.

  ## Why responses expire but rows do not

  A cache that never expired would be wrong for most of what we read:
  the corpus search query carries no date, so the same topic would return
  the same page forever and the library would stop growing, and mentions
  would freeze the moment the first poll landed. So each endpoint
  declares how long its answer stays good for.

  Rows are kept regardless. Once expired a row stops being served, but it
  still records that we paid for that call and what came back — which is
  what makes `spend_report/1` possible and what stops a bug from
  re-buying history.
  """

  import Ecto.Query

  require Logger

  alias SuperX.ApiCache.ApiResponse
  alias SuperX.Repo

  # How long each endpoint's answer stays good for, in seconds.
  #
  # Set by how fast the underlying thing actually changes, not by how
  # much we would like to save: mentions drive a reply inbox and are
  # nearly useless stale, while a search for high-performing posts on a
  # topic barely moves within a day.
  @ttls %{
    "/twitter/tweet/advanced_search" => 24 * 3600,
    "/twitter/user/last_tweets" => 6 * 3600,
    "/twitter/user/mentions" => 300,
    "/twitter/tweet/replies" => 3600,
    "/twitter/user/followers" => 24 * 3600,
    "/twitter/list/tweets" => 3600
  }

  @provider "twitterapi.io"

  @doc """
  Returns a cached response, or runs `fun` and stores what it returns.

  `fun` must return `{:ok, body}` or `{:error, reason}`. Errors are never
  cached — a 500 is not an answer, and caching one would turn a blip into
  an outage lasting the whole TTL.

  ## Options

    * `:ttl` — seconds the answer stays good for, overriding the
      endpoint's entry in `@ttls`. Callers whose freshness needs differ
      from the default (metrics feeding automations, versus a voice
      profile) use this rather than weakening the default for everyone.

  """
  def fetch(path, params, fun, opts \\ []) when is_function(fun, 0) do
    hash = hash(params)
    ttl = Keyword.get(opts, :ttl) || ttl(path)

    case lookup(@provider, path, hash, ttl) do
      {:ok, body} ->
        {:ok, body}

      :miss ->
        case fun.() do
          {:ok, body} ->
            store(@provider, path, hash, params, body)
            {:ok, body}

          error ->
            error
        end
    end
  end

  defp ttl(path), do: Map.fetch!(@ttls, path)

  defp lookup(provider, path, hash, ttl) do
    cutoff = DateTime.add(DateTime.utc_now(), -ttl, :second)

    query =
      from(r in ApiResponse,
        where:
          r.provider == ^provider and r.path == ^path and r.params_hash == ^hash and
            r.fetched_at > ^cutoff,
        select: r
      )

    case Repo.one(query) do
      nil ->
        :miss

      row ->
        # Best-effort: a failed bookkeeping update must not fail the read.
        from(r in ApiResponse, where: r.id == ^row.id)
        |> Repo.update_all(
          inc: [hit_count: 1],
          set: [last_hit_at: DateTime.utc_now()]
        )

        Logger.debug("api cache hit #{path} (saved #{row.record_count} record(s))")
        {:ok, row.body}
    end
  end

  defp store(provider, path, hash, params, body) do
    now = DateTime.utc_now()

    Repo.insert_all(
      ApiResponse,
      [
        %{
          id: Ecto.UUID.generate(),
          provider: provider,
          path: path,
          params_hash: hash,
          params: stringify(params),
          body: body,
          record_count: count_records(body),
          fetched_at: now,
          hit_count: 0,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:body, :record_count, :fetched_at, :params, :updated_at]},
      conflict_target: [:provider, :path, :params_hash]
    )

    :ok
  rescue
    # The cache is an optimisation. If writing to it fails, the caller
    # already has its answer and should not be punished for our bookkeeping.
    error ->
      Logger.warning("api cache write failed for #{path}: #{inspect(error)}")
      :ok
  end

  # Params are canonicalised before hashing so that map ordering — which
  # Elixir does not guarantee — cannot produce two keys for one call.
  defp hash(params) do
    params
    |> stringify()
    |> Enum.sort()
    |> Enum.map_join("\0", fn {k, v} -> "#{k}=#{v}" end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stringify(params) when is_map(params) do
    Map.new(params, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  # What the provider bills for. Mirrors the shapes the client already
  # knows the envelope takes.
  defp count_records(body) when is_map(body) do
    cond do
      is_list(body["tweets"]) -> length(body["tweets"])
      is_list(body["followers"]) -> length(body["followers"])
      is_list(body["data"]) -> length(body["data"])
      is_list(get_in(body, ["data", "tweets"])) -> length(get_in(body, ["data", "tweets"]))
      true -> 1
    end
  end

  defp count_records(_), do: 0

  @doc """
  What the reads have cost and what the cache saved.

  `record_count` is the billable unit, so `bought` is the bill and
  `served_from_cache` is what it would have been without this table.
  """
  def spend_report(opts \\ []) do
    since = opts[:since] || DateTime.add(DateTime.utc_now(), -30 * 24 * 3600, :second)

    from(r in ApiResponse,
      where: r.fetched_at > ^since,
      group_by: r.path,
      select: %{
        path: r.path,
        calls: count(r.id),
        bought: sum(r.record_count),
        served_from_cache: sum(r.hit_count),
        saved: sum(r.hit_count * r.record_count)
      },
      order_by: [desc: sum(r.record_count)]
    )
    |> Repo.all()
  end
end
