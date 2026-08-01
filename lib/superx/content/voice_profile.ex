defmodule SuperX.Content.VoiceProfile do
  @moduledoc """
  The writing identity and response preferences for one account.

  Voice evidence comes only from the account's own posts and bio. Selected
  creators live here as handles rather than style examples so writing can
  draw on their ideas without confusing their register for the user's.
  `rules` remains user-authored and survives every regeneration.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.XAccount

  schema "voice_profiles" do
    belongs_to :x_account, XAccount

    field :about, :string
    field :topics, :string
    field :questions, {:array, :string}, default: []
    # Derived mechanics, regenerated with the profile.
    field :style_notes, :string
    # User-authored overrides, never touched by regeneration.
    field :rules, :string

    field :inspiration_handles, {:array, :string}, default: []
    field :use_own_posts, :boolean, default: true

    field :reply_length, :string
    field :reply_question_policy, :string

    field :source_post_ids, {:array, :string}, default: []
    field :generated_at, :utc_datetime
    field :version, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :x_account_id,
      :about,
      :topics,
      :questions,
      :style_notes,
      :rules,
      :inspiration_handles,
      :use_own_posts,
      :reply_length,
      :reply_question_policy,
      :source_post_ids,
      :generated_at,
      :version
    ])
    |> validate_required([:x_account_id])
    |> validate_length(:about, max: 4000)
    |> validate_length(:rules, max: 4000)
    |> normalize_inspiration_handles()
    |> validate_length(:inspiration_handles, max: 3)
    |> validate_inspiration_handles()
    |> validate_inclusion(:reply_length, ~w(short medium long))
    |> validate_inclusion(:reply_question_policy, ~w(ask never))
    |> unique_constraint(:x_account_id)
  end

  # Accept handles typed as "@name", "name", or a full profile URL.
  defp normalize_inspiration_handles(changeset) do
    update_change(changeset, :inspiration_handles, fn handles ->
      handles
      |> Enum.map(fn handle ->
        handle
        |> String.trim()
        |> String.replace(~r{^(https?://)?(www\.)?(x|twitter)\.com/}i, "")
        |> String.trim_leading("@")
        |> String.split("/", parts: 2)
        |> hd()
        |> String.downcase()
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end)
  end

  defp validate_inspiration_handles(changeset) do
    validate_change(changeset, :inspiration_handles, fn :inspiration_handles, handles ->
      if Enum.all?(handles, &Regex.match?(~r/^[A-Za-z0-9_]{1,15}$/, &1)) do
        []
      else
        [inspiration_handles: "must contain valid X handles"]
      end
    end)
  end

  @doc """
  Search terms used to pull candidate posts from the corpus. Falls back
  to the account bio when the profile has no topics yet.
  """
  def topic_list(%__MODULE__{topics: topics}) when is_binary(topics) and topics != "" do
    topics
    |> String.split(~r/[,\n;]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def topic_list(_), do: []
end
