defmodule SuperX.Billing.CreditEntry do
  @moduledoc """
  One line in the append-only credit ledger.

  Rows are never updated or deleted — a refund is a positive entry, not a
  reversal — so the history stays auditable and disputes are answerable.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.User

  @reasons ~w(generation ask improve refund)

  schema "credit_ledger" do
    belongs_to :user, User

    field :delta, :integer
    field :balance_after, :integer

    field :reason, :string
    field :ref_type, :string
    field :ref_id, :binary_id
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:user_id, :delta, :balance_after, :reason, :ref_type, :ref_id, :metadata])
    |> validate_required([:user_id, :delta, :balance_after, :reason])
    |> validate_inclusion(:reason, @reasons)
    |> validate_number(:delta, not_equal_to: 0)
  end
end
