defmodule SuperX.Engage.Feed do
  @moduledoc """
  A saved search the user watches for conversations worth joining.

  The query is X's own search grammar, so anything that works in X search
  works here. Ranking is stored in product terms and translated at the API
  boundary, keeping a provider's vocabulary out of the rest of the app.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.XAccount

  @rankings ~w(relevance newest)

  @suggestions [
    %{
      name: "Artificial Intelligence",
      query: "\"machine learning\" OR \"generative AI\" OR LLM"
    },
    %{name: "Build in Public", query: "\"build in public\" OR #buildinpublic"},
    %{name: "Startups", query: "startup founder OR bootstrapped OR entrepreneurship"},
    %{
      name: "Technology",
      query: "\"emerging technology\" OR \"tech industry\" OR innovation"
    },
    %{name: "Design", query: "\"product design\" OR \"UX design\" OR \"graphic design\""},
    %{
      name: "Software Development",
      query: "\"software engineering\" OR programming OR developer"
    },
    %{
      name: "Marketing",
      query: "\"content marketing\" OR \"growth marketing\" OR \"brand strategy\""
    },
    %{
      name: "Business & Finance",
      query: "\"business strategy\" OR markets OR investing"
    },
    %{
      name: "Personal Finance",
      query: "budgeting OR \"financial independence\" OR \"money management\""
    },
    %{
      name: "Cryptocurrency",
      query: "bitcoin OR ethereum OR blockchain -airdrop -giveaway"
    },
    %{name: "Science", query: "\"scientific research\" OR \"peer reviewed\" OR discovery"},
    %{
      name: "Health & Fitness",
      query: "workout OR nutrition OR \"strength training\" OR wellbeing"
    },
    %{name: "Career", query: "\"career development\" OR \"job search\" OR workplace"},
    %{name: "Memes", query: "\"viral meme\" OR \"reaction image\" OR \"internet humour\""}
  ]

  @min_author_followers 100
  @min_visible_engagement 5

  schema "feeds" do
    belongs_to :x_account, XAccount

    field :name, :string
    field :query, :string
    field :min_likes, :integer, default: 50
    field :ranking, :string, default: "relevance"
    field :enabled, :boolean, default: true
    field :last_synced_at, :utc_datetime

    has_many :engagements, SuperX.Engage.Engagement

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :x_account_id,
      :name,
      :query,
      :min_likes,
      :ranking,
      :enabled,
      :last_synced_at
    ])
    |> validate_required([:x_account_id, :query])
    |> validate_length(:query, min: 2, max: 200)
    |> validate_number(:min_likes, greater_than_or_equal_to: 0)
    |> validate_inclusion(:ranking, @rankings)
    |> put_default_name()
    # Attached to :query rather than the composite's first field, so the
    # error lands on the input the user can actually change.
    |> unique_constraint(:query,
      name: :feeds_x_account_id_query_index,
      message: "is already a feed"
    )
  end

  # The query is usually a fine label; naming it is optional busywork.
  defp put_default_name(changeset) do
    case {get_field(changeset, :name), get_field(changeset, :query)} do
      {nil, query} when is_binary(query) -> put_change(changeset, :name, query)
      {"", query} when is_binary(query) -> put_change(changeset, :name, query)
      _ -> changeset
    end
  end

  @doc "The ready-made catalogue offered alongside custom searches."
  def suggestions, do: @suggestions

  @doc false
  def search_type(%__MODULE__{ranking: "newest"}), do: "Latest"
  def search_type(%__MODULE__{}), do: "Top"

  @doc false
  def passes_quality_floor?(tweet) when is_map(tweet) do
    author = tweet["author"] || %{}

    visible_engagement =
      metric(tweet, "likeCount") + metric(tweet, "retweetCount") +
        metric(tweet, "replyCount") + metric(tweet, "quoteCount")

    # Reach and visible response together remove empty bulk-created accounts
    # and posts nobody engaged with. This is not a bot classifier: established
    # automation and bought audiences can pass, while genuine new authors may not.
    metric(author, "followers") >= @min_author_followers and
      visible_engagement >= @min_visible_engagement
  end

  defp metric(payload, key) do
    case payload[key] do
      value when is_integer(value) and value > 0 -> value
      _ -> 0
    end
  end
end
