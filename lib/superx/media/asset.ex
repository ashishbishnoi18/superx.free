defmodule SuperX.Media.Asset do
  @moduledoc false

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.{User, XAccount}

  schema "media_assets" do
    field :key, :string

    belongs_to :user, User
    belongs_to :x_account, XAccount

    timestamps(type: :utc_datetime)
  end

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [:key])
    |> validate_required([:key, :user_id, :x_account_id])
    |> unique_constraint(:key)
  end
end
