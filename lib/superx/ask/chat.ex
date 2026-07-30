defmodule SuperX.Ask.Chat do
  @moduledoc "One conversation."

  use SuperX.Schema

  import Ecto.Changeset

  schema "chats" do
    belongs_to :user, SuperX.Accounts.User
    belongs_to :x_account, SuperX.Accounts.XAccount

    field :title, :string

    has_many :messages, SuperX.Ask.Message, preload_order: [asc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(chat, attrs) do
    chat
    |> cast(attrs, [:user_id, :x_account_id, :title])
    |> validate_required([:user_id, :x_account_id])
    |> validate_length(:title, max: 120)
  end
end
