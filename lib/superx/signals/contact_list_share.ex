defmodule SuperX.Signals.ContactListShare do
  @moduledoc """
  A revocable capability URL for one contact list.

  Replacing a share rotates its token, while revocation remains recorded so
  an old capability cannot become valid again by accident.
  """

  use SuperX.Schema

  import Ecto.Changeset

  schema "contact_list_shares" do
    belongs_to :contact_list, SuperX.Signals.ContactList

    field :token, :string
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(share, attrs) do
    share
    |> cast(attrs, [:token, :revoked_at])
    |> validate_required(:token)
    |> validate_length(:token, min: 40, max: 64)
    |> unique_constraint(:contact_list_id)
    |> unique_constraint(:token)
  end
end
