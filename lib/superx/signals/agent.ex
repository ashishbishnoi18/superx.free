defmodule SuperX.Signals.Agent do
  @moduledoc """
  A standing watch on X.

  The whole configuration surface is a target and a sentence describing
  who you're looking for. There's no filter builder because the useful
  criteria — "founders who just complained about their current tool" —
  aren't expressible as filters anyway.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.XAccount

  @kinds ~w(keyword follower profile list)

  schema "signal_agents" do
    belongs_to :x_account, XAccount
    belongs_to :contact_list, SuperX.Signals.ContactList

    field :name, :string
    field :kind, :string
    field :target, :string

    field :ideal_customer, :string
    field :min_score, :integer, default: 60

    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime
    field :last_error, :string
    field :leads_found, :integer, default: 0

    has_many :leads, SuperX.Signals.Lead, foreign_key: :signal_agent_id

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  @doc false
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :x_account_id,
      :contact_list_id,
      :name,
      :kind,
      :target,
      :ideal_customer,
      :min_score,
      :enabled,
      :last_run_at,
      :last_error,
      :leads_found
    ])
    |> validate_required([:x_account_id, :kind, :target])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:min_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> normalize_target()
    |> put_default_name()
  end

  # Handles arrive as "@name", "name", or a profile URL depending on where
  # the user copied them from.
  defp normalize_target(changeset) do
    kind = get_field(changeset, :kind)

    if kind in ~w(follower profile) do
      update_change(changeset, :target, fn target ->
        target
        |> String.trim()
        |> String.replace(~r{^(https?://)?(www\.)?(x|twitter)\.com/}i, "")
        |> String.trim_leading("@")
        |> String.split("/", parts: 2)
        |> hd()
      end)
    else
      changeset
    end
  end

  defp put_default_name(changeset) do
    case {get_field(changeset, :name), get_field(changeset, :kind), get_field(changeset, :target)} do
      {name, kind, target} when name in [nil, ""] and is_binary(target) ->
        put_change(changeset, :name, default_name(kind, target))

      _ ->
        changeset
    end
  end

  defp default_name("follower", target), do: "Followers of @#{target}"
  defp default_name("profile", target), do: "Activity of @#{target}"
  defp default_name("list", target), do: "Activity in list #{target}"
  defp default_name(_keyword, target), do: target

  @doc "One-line description of what this watch does, for the agent list."
  def describes(%__MODULE__{kind: "follower", target: t}), do: "new followers of @#{t}"
  def describes(%__MODULE__{kind: "profile", target: t}), do: "people engaging with @#{t}"
  def describes(%__MODULE__{kind: "list", target: t}), do: "people posting in list #{t}"
  def describes(%__MODULE__{kind: "keyword", target: t}), do: "posts matching #{t}"
end
