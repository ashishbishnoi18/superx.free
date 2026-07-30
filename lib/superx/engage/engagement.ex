defmodule SuperX.Engage.Engagement do
  @moduledoc """
  Something on X waiting on a response — a mention, a reply to one of your
  posts, or a post surfaced from a topic feed.

  Deduplicated per account by `x_post_id`, so polling the same window
  repeatedly updates metrics rather than growing the inbox.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.XAccount

  @kinds ~w(mention reply feed)
  @statuses ~w(open replied ignored)

  schema "engagements" do
    belongs_to :x_account, XAccount
    belongs_to :feed, SuperX.Engage.Feed
    belongs_to :replied_post, SuperX.Content.Post

    field :kind, :string
    field :status, :string, default: "open"

    field :x_post_id, :string
    field :conversation_id, :string
    field :in_reply_to_x_post_id, :string

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

    field :posted_at, :utc_datetime

    field :priority, :integer
    field :priority_reason, :string

    field :replied_at, :utc_datetime

    has_many :reply_drafts, SuperX.Engage.ReplyDraft

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  @doc false
  def changeset(engagement, attrs) do
    engagement
    |> cast(attrs, [
      :x_account_id,
      :feed_id,
      :kind,
      :status,
      :x_post_id,
      :conversation_id,
      :in_reply_to_x_post_id,
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
      :posted_at,
      :priority,
      :priority_reason
    ])
    |> validate_required([:x_account_id, :kind, :x_post_id, :author_handle, :text, :posted_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:x_account_id, :x_post_id])
  end

  @doc "Permalink to the post on X."
  def url(%__MODULE__{author_handle: handle, x_post_id: id}),
    do: "https://x.com/#{handle}/status/#{id}"

  @doc """
  A cheap priority used before the scorer has run, and as a fallback when
  no LLM is configured.

  Reach matters, but a reply from a small account that took effort to
  write is usually worth more than a one-word "this" from a big one, so
  length counts too.
  """
  def heuristic_priority(%__MODULE__{} = e) do
    reach = :math.log(max(e.author_followers, 10)) / :math.log(1_000_000) * 55
    effort = min(String.length(e.text) / 180, 1.0) * 25
    traction = min((e.likes + e.reposts * 2) / 40, 1.0) * 20

    round(reach + effort + traction) |> min(100) |> max(0)
  end
end
