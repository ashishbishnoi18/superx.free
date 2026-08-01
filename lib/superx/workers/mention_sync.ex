defmodule SuperX.Workers.MentionSync do
  @moduledoc """
  Polls mentions and topic feeds, scores what comes back, and files it in
  the Engage inbox.

  Both reads bill per record, so each account gets a bounded pull per run
  rather than "everything since last time" — an account that gets a
  thousand mentions overnight should cost the same as one that gets ten.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 2, unique: [period: 300]

  import Ecto.Query

  require Logger

  alias SuperX.Accounts.XAccount
  alias SuperX.Engage.Replier
  alias SuperX.{Engage, Repo, TwitterAPI}

  @mentions_per_account 25
  @feed_posts_per_feed 20

  @impl Oban.Worker
  def perform(_job) do
    if TwitterAPI.configured?() do
      sync_mentions()
      sync_feeds()
    else
      Logger.debug("Skipping engagement sync: twitterapi.io not configured")
    end

    :ok
  end

  defp sync_mentions do
    XAccount
    |> where([a], not a.reauth_needed)
    |> Repo.all()
    |> Enum.each(&sync_account_mentions/1)
  end

  defp sync_account_mentions(%XAccount{} = account) do
    case TwitterAPI.mentions(account.handle, max: @mentions_per_account) do
      {:ok, []} ->
        :ok

      {:ok, tweets} ->
        tweets
        |> Enum.map(&to_engagement(&1, account, "mention"))
        |> Enum.reject(&is_nil/1)
        |> store(account)

      {:error, :out_of_credits} ->
        Logger.error("Mention sync halted: twitterapi.io is out of credits")

      {:error, reason} ->
        Logger.warning("Mention sync failed for @#{account.handle}: #{inspect(reason)}")
    end
  end

  defp sync_feeds do
    Engage.feeds_due()
    |> Enum.each(fn feed ->
      case TwitterAPI.search(feed.query,
             min_likes: feed.min_likes,
             max: @feed_posts_per_feed,
             lang: "en",
             type: "Latest"
           ) do
        {:ok, tweets} ->
          tweets
          |> Enum.map(&to_engagement(&1, feed.x_account, "feed", feed.id))
          |> Enum.reject(&is_nil/1)
          # Your own posts showing up in your own discovery feed is noise.
          |> Enum.reject(
            &(String.downcase(&1.author_handle) == String.downcase(feed.x_account.handle))
          )
          |> store(feed.x_account)

          Engage.touch_feed(feed)

        {:error, reason} ->
          Logger.warning("Feed sync failed for #{inspect(feed.query)}: #{inspect(reason)}")
      end
    end)
  end

  # Scoring happens before the write so the inbox is ordered the moment it
  # renders, rather than briefly showing an arbitrary order then reshuffling.
  defp store(attrs_list, account) do
    structs = Enum.map(attrs_list, &struct(SuperX.Engage.Engagement, &1))

    scored =
      case Replier.score(account, structs) do
        {:ok, scored} -> scored
        _ -> structs
      end

    rows = Enum.map(scored, &Map.from_struct/1)

    {count, _} = Engage.upsert_many(rows)
    if count > 0, do: Logger.info("Filed #{count} engagement(s) for @#{account.handle}")
  end

  defp to_engagement(tweet, account, kind, feed_id \\ nil) do
    author = tweet["author"] || %{}

    if is_binary(tweet["id"]) and is_binary(tweet["text"]) and is_binary(author["userName"]) do
      %{
        x_account_id: account.id,
        feed_id: feed_id,
        kind: kind,
        x_post_id: tweet["id"],
        conversation_id: tweet["conversationId"],
        in_reply_to_x_post_id: tweet["inReplyToId"],
        author_handle: author["userName"],
        author_name: author["name"],
        author_avatar_url: author["profilePicture"],
        author_followers: author["followers"] || 0,
        author_verified: author["isBlueVerified"] || false,
        text: tweet["text"],
        lang: tweet["lang"],
        likes: tweet["likeCount"] || 0,
        reposts: tweet["retweetCount"] || 0,
        replies: tweet["replyCount"] || 0,
        posted_at: parse_time(tweet["createdAt"])
      }
    end
  end

  # Reuses the client's parser so one date format is understood in one place.
  defp parse_time(raw) do
    %{posted_at: at} = TwitterAPI.to_corpus_attrs(%{"createdAt" => raw, "author" => %{}})
    at
  end
end
