defmodule SuperX.Articles.Article do
  @moduledoc """
  A long-form draft and, eventually, the record of where it was published.

  Composition and publication deliberately meet at one narrow changeset:
  the editor can move work as far as `ready`, while an X integration can
  later record a publication outcome without teaching the editor how to
  publish.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.{User, XAccount}

  @statuses ~w(draft ready published)

  schema "articles" do
    belongs_to :user, User
    belongs_to :x_account, XAccount

    field :title, :string
    field :body, :string, default: ""
    field :status, :string, default: "draft"

    field :published_at, :utc_datetime
    field :x_article_id, :string
    field :permalink, :string

    field :word_count, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

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
    |> cast(attrs, [:x_article_id, :permalink, :published_at])
    |> put_change(:status, "published")
    |> put_default_published_at()
    |> put_word_count()
    |> validate_ready_content()
    |> validate_published_destination()
    |> unique_constraint(:x_article_id)
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
    if get_field(changeset, :status) in ["ready", "published"] do
      validate_required(changeset, [:title, :body])
    else
      changeset
    end
  end

  defp validate_published_destination(changeset) do
    if get_field(changeset, :status) == "published" do
      changeset
      |> validate_required([:published_at])
      |> require_publication_reference()
    else
      changeset
    end
  end

  defp require_publication_reference(changeset) do
    if present?(get_field(changeset, :x_article_id)) or present?(get_field(changeset, :permalink)) do
      changeset
    else
      add_error(changeset, :permalink, "or an X article id is required")
    end
  end

  defp put_default_published_at(changeset) do
    if is_nil(get_field(changeset, :published_at)) do
      put_change(changeset, :published_at, DateTime.utc_now() |> DateTime.truncate(:second))
    else
      changeset
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
