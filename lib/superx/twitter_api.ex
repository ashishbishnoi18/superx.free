defmodule SuperX.TwitterAPI do
  @moduledoc """
  Client for twitterapi.io — the read side of SuperX.

  This replaces self-scraping for everything the official X API can't
  afford: the corpus, mentions, replies, follower lists, and the watch
  agents behind Signals. Writes still go through X's own API with the
  user's OAuth token, because posting as someone should use credentials
  they granted us directly.

  Two things shape every call here:

    * **Rate.** The free tier is 0.2 QPS — one request per five seconds.
      Exceeding it earns 429s, so requests are serialised through a token
      bucket rather than fired concurrently and retried.

    * **Cost.** Calls bill per record returned (advanced search is roughly
      15 credits per tweet). A loop that pages "until done" can spend a
      month's budget in a minute, so every paging helper takes an explicit
      ceiling and stops at it.
  """

  use GenServer

  require Logger

  alias SuperX.ApiCache

  @base "https://api.twitterapi.io"

  # The free tier is 0.2 QPS — one call per five seconds. Pacing at exactly
  # 5000ms still earns 429s, because the server's window and ours drift, so
  # the default carries a margin. Paid plans raise QPS; set
  # TWITTERAPI_IO_MIN_INTERVAL_MS to match whatever you're actually on.
  @default_interval_ms 6_000

  # --- Rate limiter --------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %{last_at: nil}}

  @impl true
  def handle_call(:acquire, _from, %{last_at: last_at} = state) do
    now = System.monotonic_time(:millisecond)
    interval = interval_ms()

    wait =
      case last_at do
        nil -> 0
        at -> max(interval - (now - at), 0)
      end

    # Blocking inside the GenServer is the point: it serialises every
    # caller in the system behind one clock.
    if wait > 0, do: Process.sleep(wait)

    {:reply, :ok, %{state | last_at: System.monotonic_time(:millisecond)}}
  end

  defp acquire do
    GenServer.call(__MODULE__, :acquire, :timer.minutes(2))
  catch
    :exit, _ -> :ok
  end

  # --- Public API ----------------------------------------------------------

  @doc "Whether an API key is configured."
  def configured?, do: is_binary(api_key()) and api_key() != ""

  @doc """
  Advanced search over X, using X's own search grammar.

  Options:

    * `:min_likes` — appended as `min_faves:`, filtered server-side, which
      is far cheaper than pulling everything and discarding it here
    * `:lang`, `:since`, `:until`
    * `:type` — `"Top"` (default) or `"Latest"`
    * `:max` — hard ceiling on tweets returned (default 40)
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    full_query = build_query(query, opts)
    max = opts[:max] || 40

    paginate(
      "/twitter/tweet/advanced_search",
      %{
        "query" => full_query,
        "queryType" => opts[:type] || "Top"
      },
      max,
      "tweets"
    )
  end

  @doc "Recent posts by one account — used to derive a voice profile."
  def user_tweets(handle, opts \\ []) do
    paginate(
      "/twitter/user/last_tweets",
      %{"userName" => strip(handle)},
      opts[:max] || 40,
      "tweets"
    )
  end

  @doc """
  Mentions of an account, newest first.

  Takes `userName`, not `screen_name` — the published docs say otherwise
  and the API rejects it with a 400.
  """
  def mentions(handle, opts \\ []) do
    paginate("/twitter/user/mentions", %{"userName" => strip(handle)}, opts[:max] || 40, "tweets")
  end

  @doc "Replies to a specific post."
  def replies(tweet_id, opts \\ []) do
    paginate("/twitter/tweet/replies", %{"tweetId" => tweet_id}, opts[:max] || 40, "tweets")
  end

  @doc "Profile for a single handle."
  def user_info(handle) do
    case get("/twitter/user/info", %{"userName" => strip(handle)}) do
      {:ok, %{"data" => data}} when is_map(data) -> {:ok, normalize_author(data)}
      {:ok, body} -> {:error, {:unexpected_response, body}}
      error -> error
    end
  end

  @doc "Followers of an account — the Signals follower watch."
  def followers(handle, opts \\ []) do
    case paginate(
           "/twitter/user/followers",
           %{"userName" => strip(handle)},
           opts[:max] || 40,
           "followers"
         ) do
      {:ok, items} -> {:ok, Enum.map(items, &normalize_author/1)}
      error -> error
    end
  end

  @doc "Timeline of an X list — the Signals list watch."
  def list_timeline(list_id, opts \\ []) do
    paginate("/twitter/list/tweets_timeline", %{"listId" => list_id}, opts[:max] || 40, "tweets")
  end

  @doc """
  Seam for the authenticated user's Direct Message inbox.

  twitterapi.io publishes only a per-participant history endpoint. It
  requires the user's login cookies and a proxy, and cannot enumerate an
  OAuth user's conversations. Those credentials do not belong in SuperX,
  so there is no safe provider request to put through `SuperX.ApiCache`.
  """
  def direct_messages(_x_user_id), do: {:error, :dm_read_unavailable}

  # --- Normalisation -------------------------------------------------------

  @doc """
  Maps a twitterapi.io tweet onto the attrs `SuperX.Content.Corpus`
  expects, so ingestion is a straight pass-through.
  """
  def to_corpus_attrs(tweet) do
    author = tweet["author"] || %{}

    %{
      x_post_id: tweet["id"],
      author_handle: author["userName"],
      author_name: author["name"],
      author_avatar_url: upscale_avatar(author["profilePicture"]),
      author_followers: author["followers"] || 0,
      author_verified: author["isBlueVerified"] || false,
      text: tweet["text"],
      lang: tweet["lang"],
      likes: tweet["likeCount"] || 0,
      reposts: tweet["retweetCount"] || 0,
      replies: tweet["replyCount"] || 0,
      quotes: tweet["quoteCount"] || 0,
      bookmarks: tweet["bookmarkCount"] || 0,
      impressions: tweet["viewCount"] || 0,
      posted_at: parse_time(tweet["createdAt"]),
      media: extract_media(tweet),
      # A post that opens its own conversation and drew replies is a thread
      # head, which is the shape worth learning from.
      is_thread: tweet["conversationId"] == tweet["id"] and (tweet["replyCount"] || 0) > 0,
      source: "twitterapi.io"
    }
  end

  @doc "Author fields in the shape the rest of the app uses."
  def normalize_author(user) do
    %{
      x_user_id: user["id"],
      handle: user["userName"] || user["screen_name"],
      display_name: user["name"],
      avatar_url: upscale_avatar(user["profilePicture"]),
      description: user["description"],
      followers_count: user["followers"] || 0,
      following_count: user["following"] || 0,
      posts_count: user["statusesCount"] || 0,
      verified: user["isBlueVerified"] || false,
      location: user["location"]
    }
  end

  # --- Internals -----------------------------------------------------------

  defp build_query(query, opts) do
    [
      query,
      opts[:min_likes] && "min_faves:#{opts[:min_likes]}",
      opts[:lang] && "lang:#{opts[:lang]}",
      opts[:since] && "since_time:#{DateTime.to_unix(opts[:since])}",
      opts[:until] && "until_time:#{DateTime.to_unix(opts[:until])}",
      # Replies are conversation, not composition — the corpus wants posts
      # that stand on their own.
      "-filter:replies"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  # Pages until `max` items or the API says there's nothing more. The
  # ceiling is mandatory rather than optional because each page costs money.
  defp paginate(path, params, max, key, acc \\ [], cursor \\ nil) do
    params = if cursor, do: Map.put(params, "cursor", cursor), else: params

    case get(path, params) do
      {:ok, body} ->
        acc = acc ++ extract(body, key)

        cond do
          length(acc) >= max ->
            {:ok, Enum.take(acc, max)}

          body["has_next_page"] == true and is_binary(body["next_cursor"]) and
            body["next_cursor"] != "" and extract(body, key) != [] ->
            paginate(path, params, max, key, acc, body["next_cursor"])

          true ->
            {:ok, acc}
        end

      {:error, reason} ->
        # Return what we already paid for rather than discarding it.
        if acc == [], do: {:error, reason}, else: {:ok, acc}
    end
  end

  # The envelope is not consistent across endpoints: advanced_search puts
  # tweets at the top level, last_tweets nests them under `data`, and some
  # endpoints return a bare list in `data`. Anything that isn't a list is
  # treated as empty rather than concatenated, which is what turned a shape
  # surprise into a crash the first time.
  defp extract(body, key) do
    candidates = [
      body[key],
      get_in(body, ["data", key]),
      body["data"]
    ]

    Enum.find(candidates, [], &is_list/1)
  end

  # Every read goes through the cache. The rate limiter is acquired inside
  # the miss branch rather than around it, so a cache hit is not made to
  # wait its turn behind calls that actually cost money.
  defp get(path, params) do
    ApiCache.fetch(path, params, fn -> do_get(path, params) end)
  end

  defp do_get(path, params) do
    if configured?() do
      acquire()

      req =
        Req.new(
          [
            url: @base <> path,
            params: params,
            headers: [{"x-api-key", api_key()}],
            receive_timeout: 45_000,
            retry: :transient,
            max_retries: 3,
            # Req's retries do not pass back through the rate limiter, so
            # without this they fire milliseconds apart and re-trip the very
            # 429 they're retrying. Spacing them at the plan interval is what
            # actually makes the backoff work.
            retry_delay: fn attempt -> interval_ms() * (attempt + 1) end
          ] ++ test_plug(:twitter_api_plug)
        )

      case Req.get(req) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          log_cost(path, body)
          {:ok, body}

        {:ok, %{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status: 402, body: body}} ->
          Logger.error("twitterapi.io is out of credits: #{inspect(body)}")
          {:error, :out_of_credits}

        {:ok, %{status: 429}} ->
          {:error, :rate_limited}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("twitterapi.io #{path} returned #{status}: #{inspect(body)}")
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, {:transport_error, reason}}
      end
    else
      {:error, :not_configured}
    end
  end

  # Cheap visibility on spend — this API bills per record, and the first
  # sign of a runaway loop is usually the invoice.
  defp log_cost(path, body) do
    count =
      cond do
        is_list(body["tweets"]) -> length(body["tweets"])
        is_list(body["followers"]) -> length(body["followers"])
        is_list(body["data"]) -> length(body["data"])
        true -> 1
      end

    Logger.debug("twitterapi.io #{path} -> #{count} record(s)")
  end

  defp extract_media(tweet) do
    tweet
    |> get_in(["extendedEntities", "media"])
    |> Kernel.||(get_in(tweet, ["entities", "media"]))
    |> List.wrap()
    |> Enum.map(fn m -> %{"type" => m["type"], "url" => m["media_url_https"]} end)
  end

  # twitterapi.io returns the 48px thumbnail by default.
  defp upscale_avatar(nil), do: nil
  defp upscale_avatar(url), do: String.replace(url, "_normal.", "_400x400.")

  defp strip(handle), do: handle |> to_string() |> String.trim_leading("@")

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  # The API emits X's own format, "Wed Oct 10 20:19:24 +0000 2018", which
  # nothing in Elixir parses natively. ISO is accepted too in case the
  # response shape changes; an unparseable date falls back to now rather
  # than dropping an otherwise good post.
  @created_at ~r/^\w{3} (?<mon>\w{3}) (?<day>\d{1,2}) (?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2}) [+-]\d{4} (?<year>\d{4})$/

  defp parse_time(nil), do: utc_now()

  defp parse_time(raw) when is_binary(raw) do
    case Regex.named_captures(@created_at, raw) do
      nil ->
        case DateTime.from_iso8601(raw) do
          {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
          _ -> utc_now()
        end

      caps ->
        with {:ok, month} <- Map.fetch(@months, caps["mon"]),
             {:ok, date} <- Date.new(int(caps["year"]), month, int(caps["day"])),
             {:ok, time} <- Time.new(int(caps["h"]), int(caps["m"]), int(caps["s"])),
             {:ok, dt} <- DateTime.new(date, time, "Etc/UTC") do
          DateTime.truncate(dt, :second)
        else
          _ -> utc_now()
        end
    end
  end

  defp parse_time(_), do: utc_now()

  defp int(s), do: String.to_integer(s)
  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp api_key, do: Application.get_env(:superx, __MODULE__, [])[:api_key]

  # Lets tests stub the wire without changing how this behaves in prod,
  # where the key is absent and the option is simply not passed.
  defp test_plug(key) do
    case Application.get_env(:superx, key) do
      nil -> []
      plug -> [plug: plug]
    end
  end

  defp interval_ms do
    Application.get_env(:superx, __MODULE__, [])[:min_interval_ms] || @default_interval_ms
  end
end
