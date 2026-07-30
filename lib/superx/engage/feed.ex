defmodule SuperX.Engage.Feed do
  @moduledoc """
  A saved search the user watches for conversations worth joining.

  The query is X's own search grammar, so anything that works in X search
  works here.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.XAccount

  schema "feeds" do
    belongs_to :x_account, XAccount

    field :name, :string
    field :query, :string
    field :min_likes, :integer, default: 50
    field :enabled, :boolean, default: true
    field :last_synced_at, :utc_datetime

    has_many :engagements, SuperX.Engage.Engagement

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [:x_account_id, :name, :query, :min_likes, :enabled, :last_synced_at])
    |> validate_required([:x_account_id, :query])
    |> validate_length(:query, min: 2, max: 200)
    |> validate_number(:min_likes, greater_than_or_equal_to: 0)
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

  @doc "Starter feeds offered to an account with none."
  def suggestions do
    [
      %{name: "Build in public", query: "\"build in public\"", min_likes: 30},
      %{name: "Indie hackers", query: "indie hacker OR bootstrapped", min_likes: 30},
      %{name: "Developer tools", query: "\"developer tools\" OR devtools", min_likes: 50},
      %{name: "AI engineering", query: "\"AI engineering\" OR \"LLM apps\"", min_likes: 50}
    ]
  end
end
