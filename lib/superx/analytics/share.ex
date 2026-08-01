defmodule SuperX.Analytics.Share do
  @moduledoc """
  A revocable capability URL for a fixed analytics window.

  The token is the authority to read the summary. Storing dates rather than
  a rolling duration keeps the shared window stable, while revocation is
  retained as state so an old URL cannot silently become active again.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.XAccount

  schema "analytics_shares" do
    belongs_to :x_account, XAccount

    field :token, :string
    field :from_date, :date
    field :to_date, :date
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(share, attrs) do
    share
    |> cast(attrs, [:x_account_id, :token, :from_date, :to_date, :revoked_at])
    |> validate_required([:x_account_id, :token, :from_date, :to_date])
    |> validate_length(:token, min: 40, max: 64)
    |> validate_date_order()
    |> unique_constraint(:x_account_id)
    |> unique_constraint(:token)
  end

  defp validate_date_order(changeset) do
    from = get_field(changeset, :from_date)
    to = get_field(changeset, :to_date)

    if from && to && Date.after?(from, to) do
      add_error(changeset, :to_date, "must be on or after the start date")
    else
      changeset
    end
  end
end
