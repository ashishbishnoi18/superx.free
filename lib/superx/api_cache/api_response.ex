defmodule SuperX.ApiCache.ApiResponse do
  @moduledoc """
  One paid upstream call and what it returned.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_responses" do
    field :provider, :string
    field :path, :string
    field :params_hash, :string
    field :params, :map, default: %{}
    field :body, :map
    field :record_count, :integer, default: 0
    field :fetched_at, :utc_datetime_usec
    field :hit_count, :integer, default: 0
    field :last_hit_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
