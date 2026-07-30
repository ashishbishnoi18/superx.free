defmodule SuperX.Content.Voice do
  @moduledoc """
  Derives an account's writing voice from its own posts.

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
    case SuperX.X.Tokens.fresh_token(account) do
      {:ok, token, account} ->
        case SuperX.X.get_user_posts(token, account.x_user_id, limit: 100) do
          {:ok, posts} ->
            {:ok, posts}

          {:error, reason} ->
            Logger.warning("Could not fetch posts for @#{account.handle}: #{inspect(reason)}")
            # A voice can still be inferred from the bio alone.
            {:ok, []}
        end

      {:error, :reauth_required} ->
        {:error, :reauth_required}

      {:error, reason} ->
        {:error, reason}
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
end
