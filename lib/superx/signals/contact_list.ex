defmodule SuperX.Signals.ContactList do
  @moduledoc """
  A saved audience with an explicit membership contract.

  Manual lists and the protected Followers list store memberships. Engage
  deliberately does not: it is a query over the contact workflow, so it can
  never become stale or disagree with the status shown on a contact.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.XAccount

  @kinds ~w(manual followers engage)

  schema "contact_lists" do
    belongs_to :x_account, XAccount

    field :name, :string
    field :kind, :string, default: "manual"

    has_many :memberships, SuperX.Signals.ContactListMembership
    has_many :leads, through: [:memberships, :lead]
    has_one :share, SuperX.Signals.ContactListShare

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(list, attrs) do
    list
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required(:name)
    |> validate_length(:name, max: 60)
    |> unique_constraint([:x_account_id, :name])
  end

  def editable?(%__MODULE__{kind: kind}), do: kind in ~w(manual followers)
  def deletable?(%__MODULE__{kind: "manual"}), do: true
  def deletable?(%__MODULE__{}), do: false
  def derived?(%__MODULE__{kind: "engage"}), do: true
  def derived?(%__MODULE__{}), do: false

  def kinds, do: @kinds
end
