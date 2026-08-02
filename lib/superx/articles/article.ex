defmodule SuperX.Articles.Article do
  @moduledoc """
  A long-form draft and the record of where X published it.

  Composition and publication deliberately meet at one narrow changeset:
  the editor owns prose and review state, while the publisher alone can
  attach X identifiers and make the article immutable.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.{User, XAccount}

  @statuses ~w(draft ready publishing published)
  @visible_statuses ~w(draft ready published)

  schema "articles" do
    belongs_to :user, User
    belongs_to :x_account, XAccount

    field :title, :string
    field :body, :string, default: ""
    field :status, :string, default: "draft"

    field :published_at, :utc_datetime
    field :x_article_id, :string
    field :x_post_id, :string
    field :permalink, :string
    field :publish_error, :string

    field :word_count, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @visible_statuses

  @doc false
  def changeset(article, attrs) do
    article
    |> cast(attrs, [:title, :body, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:title, max: 240)
    |> put_word_count()
    |> validate_ready_content()
    |> validate_published_destination()
  end

  @doc false
  def publication_changeset(article, attrs) do
    article
    |> cast(attrs, [:x_article_id, :x_post_id, :permalink, :published_at])
    |> put_change(:status, "published")
    |> put_change(:publish_error, nil)
    |> put_default_published_at()
    |> put_word_count()
    |> validate_ready_content()
    |> validate_published_destination()
    |> unique_constraint(:x_article_id)
    |> unique_constraint(:x_post_id)
  end

  @doc "Counts words using the same whitespace boundary shown in the editor."
  def count_words(nil), do: 0

  def count_words(body) when is_binary(body) do
    body
    |> String.split(~r/\s+/u, trim: true)
    |> length()
  end

  defp put_word_count(changeset) do
    put_change(changeset, :word_count, count_words(get_field(changeset, :body)))
  end

  defp validate_ready_content(changeset) do
    if get_field(changeset, :status) in ["ready", "publishing", "published"] do
      validate_required(changeset, [:title, :body])
    else
      changeset
    end
  end

  defp validate_published_destination(changeset) do
    if get_field(changeset, :status) == "published" do
      changeset
      |> validate_required([:published_at, :x_article_id, :x_post_id, :permalink])
    else
      changeset
    end
  end

  defp put_default_published_at(changeset) do
    if is_nil(get_field(changeset, :published_at)) do
      put_change(changeset, :published_at, DateTime.utc_now() |> DateTime.truncate(:second))
    else
      changeset
    end
  end
end
