defmodule SuperX.Signals.Lead do
  @moduledoc """
  Someone an agent found and thought was worth keeping.

  Deduplicated per account by handle: the same person turning up in two
  watches is one lead with the better score, not two rows.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.XAccount

  @statuses ~w(new contacted replied won archived)

  schema "leads" do
    belongs_to :x_account, XAccount
    belongs_to :signal_agent, SuperX.Signals.Agent

    has_many :contact_list_memberships, SuperX.Signals.ContactListMembership
    has_many :contact_lists, through: [:contact_list_memberships, :contact_list]

    field :x_user_id, :string
    field :handle, :string
    field :display_name, :string
    field :avatar_url, :string
    field :bio, :string
    field :location, :string

    field :followers_count, :integer, default: 0
    field :following_count, :integer, default: 0
    field :verified, :boolean, default: false

    field :score, :integer
    field :reason, :string
    field :source_post_id, :string
    field :source_post_text, :string

    field :status, :string, default: "new"
    field :notes, :string
    field :contacted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc false
  def changeset(lead, attrs) do
    lead
    |> cast(attrs, [
      :x_account_id,
      :signal_agent_id,
      :x_user_id,
      :handle,
      :display_name,
      :avatar_url,
      :bio,
      :location,
      :followers_count,
      :following_count,
      :verified,
      :score,
      :reason,
      :source_post_id,
      :source_post_text,
      :status,
      :notes,
      :contacted_at
    ])
    |> validate_required([:x_account_id, :handle])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:x_account_id, :handle])
  end

  def url(%__MODULE__{handle: handle}), do: "https://x.com/#{handle}"

  def source_url(%__MODULE__{handle: handle, source_post_id: id}) when is_binary(id),
    do: "https://x.com/#{handle}/status/#{id}"

  def source_url(_), do: nil
end
