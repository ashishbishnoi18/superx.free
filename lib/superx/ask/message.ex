defmodule SuperX.Ask.Message do
  @moduledoc """
  One turn in a conversation.

  `tool_calls` holds a plain-language summary of what the assistant
  actually did — read analytics, queued a post — so the user can see the
  actions rather than taking the prose on trust.
  """

  use SuperX.Schema

  import Ecto.Changeset

  @roles ~w(user assistant)

  schema "chat_messages" do
    belongs_to :chat, SuperX.Ask.Chat

    field :role, :string
    field :content, :string
    field :tool_calls, {:array, :map}, default: []
    field :credits_cost, :integer, default: 0

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:chat_id, :role, :content, :tool_calls, :credits_cost])
    |> validate_required([:chat_id, :role, :content])
    |> validate_inclusion(:role, @roles)
  end
end
