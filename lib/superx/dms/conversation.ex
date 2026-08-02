defmodule SuperX.DMs.Conversation do
  @moduledoc """
  One private one-to-one thread belonging to a connected X account.

  The participant id is the stable identity and the send address. Handles
  are display data and may change, while X's conversation id is optional
  until a read or successful first send supplies it.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.XAccount
  alias SuperX.DMs.Message

  schema "dm_conversations" do
    belongs_to :x_account, XAccount

    field :x_conversation_id, :string
    field :participant_x_user_id, :string
    field :participant_handle, :string
    field :participant_name, :string
    field :participant_avatar_url, :string
    field :encrypted, :boolean, default: false

    field :last_message_text, :string
    field :last_message_at, :utc_datetime
    field :last_synced_at, :utc_datetime

    has_many :messages, Message

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :x_conversation_id,
      :participant_x_user_id,
      :participant_handle,
      :participant_name,
      :participant_avatar_url,
      :encrypted,
      :last_message_text,
      :last_message_at,
      :last_synced_at
    ])
    |> validate_required([:participant_x_user_id])
    |> validate_format(:participant_x_user_id, ~r/^\d+$/, message: "must be an X user id")
    |> unique_constraint([:x_account_id, :participant_x_user_id])
    |> unique_constraint([:x_account_id, :x_conversation_id])
  end
end
