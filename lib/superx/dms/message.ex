defmodule SuperX.DMs.Message do
  @moduledoc """
  An immutable X Direct Message event stored under both its account and
  conversation.

  The repeated account key makes the privacy boundary explicit in queries
  and lets X's globally-scoped event id deduplicate without joining through
  the conversation.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.XAccount
  alias SuperX.DMs.Conversation

  @directions ~w(inbound outbound)

  schema "dm_messages" do
    belongs_to :x_account, XAccount
    belongs_to :conversation, Conversation

    field :x_message_id, :string
    field :sender_x_user_id, :string
    field :direction, :string
    field :text, :string
    field :sent_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def directions, do: @directions

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:x_message_id, :sender_x_user_id, :direction, :text, :sent_at])
    |> validate_required([:x_message_id, :sender_x_user_id, :direction, :text, :sent_at])
    |> validate_inclusion(:direction, @directions)
    |> unique_constraint([:x_account_id, :x_message_id])
  end
end
