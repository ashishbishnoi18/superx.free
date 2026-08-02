defmodule SuperX.Content.Voice do
  @moduledoc """
  Derives an account's writing voice from its own posts and gathers idea
  material without letting other authors redefine that voice.

  Run at connect time and re-runnable on demand. Regeneration deliberately
  preserves `rules` — those are the user's own instructions, and silently
  discarding them when they press "regenerate" would be the worst kind of
  surprise.
  """

  require Logger

  alias SuperX.{AI, Content}
  alias SuperX.AI.Prompts
  alias SuperX.Accounts.XAccount
  alias SuperX.Content.VoiceProfile
  alias SuperX.TwitterAPI

  @inspiration_posts_per_creator 5

  @doc """
  Rebuilds the voice profile for an account from its recent posts.

  `posts` is a list of X API post maps; when omitted they're fetched.
  """
  @spec derive(XAccount.t(), keyword()) :: {:ok, VoiceProfile.t()} | {:error, term()}
  def derive(%XAccount{} = account, opts \\ []) do
    with {:ok, posts} <- fetch_posts(account, opts[:posts]),
         {:ok, result} <- ask(account, posts) do
      {:ok, profile} = Content.get_or_create_voice_profile(account)

      Content.update_voice_profile(profile, %{
        about: result["about"],
        topics: result["topics"],
        questions: result["questions"] || [],
        style_notes: result["style_notes"],
        source_post_ids: Enum.map(posts, &(&1["id"] || "")) |> Enum.reject(&(&1 == "")),
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
        version: profile.version + 1
      })
    end
  end

  defp ask(account, posts) do
    AI.structured(
      Prompts.derive_voice(account, posts),
      Prompts.voice_schema(),
      model: AI.writer_model(),
      max_tokens: 1500,
      tool_description: "Return the author's voice profile."
    )
  end

  defp fetch_posts(_account, posts) when is_list(posts), do: {:ok, posts}

  defp fetch_posts(%XAccount{} = account, _nil) do
    case TwitterAPI.user_tweets(account.handle, max: 60) do
      {:ok, tweets} ->
        {:ok, Enum.map(tweets, &%{"id" => &1["id"], "text" => &1["text"]})}

      {:error, reason} ->
        Logger.warning("Could not read posts for @#{account.handle}: #{inspect(reason)}")
        {:error, {:post_fetch_failed, reason}}
    end
  end

  @doc """
  Sample posts to feed the writer as few-shot examples of the author's
  register. Prefers their own published posts, newest first.
  """
  def examples(account, profile, limit \\ 5)

  def examples(%XAccount{} = account, %VoiceProfile{use_own_posts: true}, limit) do
    import Ecto.Query

    SuperX.Content.Post
    |> where([p], p.x_account_id == ^account.id and p.status == "posted")
    |> order_by(desc: :published_at)
    |> limit(^limit)
    |> SuperX.Repo.all()
    |> Enum.map(&SuperX.Content.Post.preview_text/1)
    |> Enum.reject(&(&1 == ""))
  end

  def examples(_account, _profile, _limit), do: []

  @doc """
  Recent posts from the creators selected as idea sources.

  These remain grouped by handle so the prompt can keep them visibly apart
  from the account's own voice examples. A failed or unconfigured read is
  treated as no inspiration; writing from the user's existing topics still
  works without the paid read provider.
  """
  def inspiration_posts(%VoiceProfile{} = profile, limit \\ @inspiration_posts_per_creator) do
    if TwitterAPI.configured?() do
      (profile.inspiration_handles || [])
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
      |> Enum.take(3)
      |> Enum.map(&fetch_inspiration_posts(&1, limit))
      |> Enum.reject(&(&1.posts == []))
    else
      []
    end
  end

  # TwitterAPI owns the persistent cache boundary. Calling it here means a
  # shelf top-up reuses the records already bought by an earlier draft.
  defp fetch_inspiration_posts(handle, limit) do
    case TwitterAPI.user_tweets(handle, max: limit) do
      {:ok, posts} ->
        texts =
          posts
          |> Enum.map(&(&1["text"] || &1[:text]))
          |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))

        %{handle: handle, posts: texts}

      {:error, reason} ->
        Logger.warning("Could not read inspiration posts for @#{handle}: #{inspect(reason)}")
        %{handle: handle, posts: []}
    end
  end
end
