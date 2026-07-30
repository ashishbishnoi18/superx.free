defmodule SuperX.Content.VoiceProfile do
  @moduledoc """
  The learned writing voice for one account.

  This is what makes generated posts sound like the user rather than like
  an assistant. It is derived from the account's own posts and bio, then
  editable by hand — `rules` is always appended verbatim to the writer
  prompt so a user can override anything the model inferred.
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

    field :favorite_voices, {:array, :string}, default: []
    field :use_own_posts, :boolean, default: true

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
      :favorite_voices,
      :use_own_posts,
      :source_post_ids,
      :generated_at,
      :version
    ])
    |> validate_required([:x_account_id])
    |> validate_length(:about, max: 4000)
    |> validate_length(:rules, max: 4000)
    |> normalize_favorite_voices()
    |> unique_constraint(:x_account_id)
  end

  # Accept handles typed as "@name", "name", or a full profile URL.
  defp normalize_favorite_voices(changeset) do
    update_change(changeset, :favorite_voices, fn handles ->
      handles
      |> Enum.map(fn handle ->
        handle
        |> String.trim()
        |> String.replace(~r{^https?://(www\.)?(x|twitter)\.com/}i, "")
        |> String.trim_leading("@")
        |> String.split("/", parts: 2)
        |> hd()
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
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
