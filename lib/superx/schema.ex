defmodule SuperX.Schema do
  @moduledoc """
  Shared schema defaults: UUID primary keys and UUID foreign keys, so
  ids are safe to expose in URLs and stable across environments.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime]
    end
  end
end
