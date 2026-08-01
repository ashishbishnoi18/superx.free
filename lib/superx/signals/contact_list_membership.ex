defmodule SuperX.Signals.ContactListMembership do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "contact_list_memberships" do
    belongs_to :contact_list, SuperX.Signals.ContactList, primary_key: true
    belongs_to :lead, SuperX.Signals.Lead, primary_key: true

    timestamps(type: :utc_datetime)
  end
end
