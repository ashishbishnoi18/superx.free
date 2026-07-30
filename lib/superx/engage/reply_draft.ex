defmodule SuperX.Engage.ReplyDraft do
  @moduledoc """
  An AI-written reply waiting for approval.

  Separate from `posts` so drafts can be regenerated and discarded without
  touching anything the user has actually committed to.
  """

  use SuperX.Schema

  import Ecto.Changeset

  @statuses ~w(shelf used dismissed)

  schema "reply_drafts" do
    belongs_to :engagement, SuperX.Engage.Engagement
    belongs_to :user, SuperX.Accounts.User

    field :text, :string
    field :status, :string, default: "shelf"

    field :model, :string
    field :credits_cost, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [:engagement_id, :user_id, :text, :status, :model, :credits_cost])
    |> validate_required([:engagement_id, :user_id, :text])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:text, max: 280,
      message: "is over the character limit"
    )
  end
end
