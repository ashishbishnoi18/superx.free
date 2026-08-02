defmodule SuperX.Content.CorpusPost do
  @moduledoc """
  One high-performing post in the shared library.

  The corpus is the retrieval source for generation: a post is selected
  here, and its *structure* is rewritten in the user's voice. It is
  global rather than per-user, so ingestion cost is amortised across
  every account.
  """

  use SuperX.Schema

  import Ecto.Changeset

  schema "corpus_posts" do
    field :x_post_id, :string
    field :author_handle, :string
    field :author_name, :string
    field :author_avatar_url, :string
    field :author_followers, :integer, default: 0
    field :author_verified, :boolean, default: false

    field :text, :string
    field :lang, :string

    field :likes, :integer, default: 0
    field :reposts, :integer, default: 0
    field :replies, :integer, default: 0
    field :quotes, :integer, default: 0
    field :bookmarks, :integer, default: 0
    field :impressions, :integer, default: 0

    field :engagement_score, :float, default: 0.0
    field :follower_bucket, :integer, read_after_writes: true
    field :outlier_score, :float, virtual: true, default: 1.0
    field :posted_at, :utc_datetime

    field :media, {:array, :map}, default: []
    field :has_media, :boolean, default: false
    field :is_thread, :boolean, default: false

    field :topics, {:array, :string}, default: []
    field :embedding, Pgvector.Ecto.Vector

    field :source, :string, default: "twitterapi.io"
    field :ingested_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(post, attrs) do
    post
    |> cast(attrs, [
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
      :posted_at,
      :media,
      :is_thread,
      :topics,
      :embedding,
      :source
    ])
    |> validate_required([:x_post_id, :author_handle, :text, :posted_at])
    |> put_has_media()
    |> put_engagement_score()
    |> put_ingested_at()
    |> unique_constraint(:x_post_id)
  end

  defp put_has_media(changeset) do
    media = get_field(changeset, :media) || []
    put_change(changeset, :has_media, media != [])
  end

  defp put_ingested_at(changeset) do
    case get_field(changeset, :ingested_at) do
      nil -> put_change(changeset, :ingested_at, DateTime.utc_now() |> DateTime.truncate(:second))
      _ -> changeset
    end
  end

  # Weighted engagement normalised against author reach.
  #
  # Raw likes overwhelmingly favour accounts that are already huge, which
  # produces a corpus of celebrity posts that read as noise when rewritten
  # for a small account. Dividing by log(followers) surfaces posts that
  # genuinely outperformed their author's baseline. Replies and bookmarks
  # are weighted up because they signal a post worth responding to or
  # saving, which is what we want to imitate.
  defp put_engagement_score(changeset) do
    likes = get_field(changeset, :likes) || 0
    reposts = get_field(changeset, :reposts) || 0
    replies = get_field(changeset, :replies) || 0
    quotes = get_field(changeset, :quotes) || 0
    bookmarks = get_field(changeset, :bookmarks) || 0
    followers = get_field(changeset, :author_followers) || 0

    weighted = likes + reposts * 3 + replies * 2 + quotes * 3 + bookmarks * 4
    reach = :math.log(max(followers, 100))

    put_change(changeset, :engagement_score, Float.round(weighted / reach, 4))
  end

  @doc """
  The text used to build an embedding. Author context is included so
  similar voices cluster, not just similar wording.
  """
  def embedding_input(%__MODULE__{} = post) do
    "@#{post.author_handle}: #{post.text}"
  end
end
