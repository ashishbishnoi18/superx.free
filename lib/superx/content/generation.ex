defmodule SuperX.Content.Generation do
  @moduledoc """
  An AI-written post sitting on the Ready to Post shelf.

  Kept separate from `Post` so the shelf can be refilled, scored, and
  discarded without polluting the user's real drafts. Accepting one
  creates a `Post` that points back here via `generation_id`.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Content.CorpusPost

  @kinds ~w(for_you products trending media viral)
  @statuses ~w(shelf used dismissed)

  schema "generations" do
    belongs_to :user, User
    belongs_to :x_account, XAccount
    belongs_to :source_corpus_post, CorpusPost

    field :segments, {:array, :map}, default: []

    field :kind, :string, default: "for_you"
    field :status, :string, default: "shelf"

    field :source_likes, :integer

    field :model, :string
    field :credits_cost, :integer, default: 0
    field :score, :float

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  @doc false
  def changeset(generation, attrs) do
    generation
    |> cast(attrs, [
      :user_id,
      :x_account_id,
      :source_corpus_post_id,
      :segments,
      :kind,
      :status,
      :source_likes,
      :model,
      :credits_cost,
      :score
    ])
    |> validate_required([:user_id, :x_account_id, :segments])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_non_empty_segments()
  end

  defp validate_non_empty_segments(changeset) do
    case get_field(changeset, :segments) do
      [] -> add_error(changeset, :segments, "cannot be empty")
      _ -> changeset
    end
  end

  @doc "Full text of the generated post or thread."
  def text(%__MODULE__{segments: segments}) do
    segments |> Enum.map_join("\n\n", &(&1["text"] || "")) |> String.trim()
  end

  @doc """
  The attribution label shown under a card, e.g. "Inspired by a post with
  12.8K likes". Returns nil when the generation had no corpus source.
  """
  def attribution(%__MODULE__{source_likes: nil}), do: nil

  def attribution(%__MODULE__{source_likes: likes}) do
    "Inspired by a post with #{format_count(likes)} likes"
  end

  defp format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_count(n) when n >= 10_000, do: "#{round(n / 1_000)}K"
  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n), do: to_string(n)
end
