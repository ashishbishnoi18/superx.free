defmodule SuperX.Content.Post do
  @moduledoc """
  A post in any lifecycle state — draft, queued, published, or failed.

  A thread is modelled as an ordered list of `segments` rather than
  separate rows, so the whole thread is written, scheduled, and published
  atomically.
  """

  use SuperX.Schema

  import Ecto.Changeset

  alias SuperX.Accounts.{User, XAccount}

  @statuses ~w(draft scheduled publishing posted failed cancelled)
  @sources ~w(manual generated reply)

  # X's limit for a standard account. Premium allows more, but writing to
  # the lower bound keeps posts publishable from any connected account.
  @max_segment_length 280
  @max_media_per_segment 4

  schema "posts" do
    belongs_to :user, User
    belongs_to :x_account, XAccount
    belongs_to :generation, SuperX.Content.Generation

    field :status, :string, default: "draft"
    field :segments, {:array, :map}, default: []

    field :scheduled_at, :utc_datetime
    field :published_at, :utc_datetime

    field :x_post_ids, {:array, :string}, default: []
    field :permalink, :string

    field :error, :string
    field :failed_at, :utc_datetime
    field :attempt_count, :integer, default: 0

    field :source, :string, default: "manual"
    field :reply_to_x_post_id, :string
    field :tags, {:array, :string}, default: []

    # Post automations. A nil field means the automation is off — zero is
    # rejected in the changeset because "retweet after 0 hours" would fire
    # on the first worker tick.
    field :auto_retweet_hours, :integer
    field :auto_retweet_undo_hours, :integer
    field :auto_plug_likes, :integer
    field :auto_plug_text, :string
    field :auto_delete_min_views, :integer
    field :auto_delete_hours, :integer

    # Which automations already fired, so a re-run acts once.
    field :automation_state, :map, default: %{}

    # Last metrics pulled from X, and when, for performance-gated automations.
    field :metrics, :map, default: %{}
    field :metrics_updated_at, :utc_datetime
    field :automation_version, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def max_media_per_segment, do: @max_media_per_segment

  @positive_automation_fields [
    :auto_retweet_hours,
    :auto_retweet_undo_hours,
    :auto_plug_likes,
    :auto_delete_min_views,
    :auto_delete_hours
  ]

  @doc false
  def changeset(post, attrs) do
    post
    |> cast(attrs, [
      :status,
      :segments,
      :scheduled_at,
      :source,
      :reply_to_x_post_id,
      :tags,
      :auto_retweet_hours,
      :auto_retweet_undo_hours,
      :auto_plug_likes,
      :auto_plug_text,
      :auto_delete_min_views,
      :auto_delete_hours
    ])
    |> validate_required([:user_id, :x_account_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_positive_automations()
    |> validate_auto_plug_text()
    |> normalize_segments()
    |> validate_segments()
    |> validate_media()
    |> validate_scheduled_at()
  end

  @doc """
  Persists automation bookkeeping without re-running composer validations.

  Workers write state and metrics on posts that are already live; routing
  those writes through `changeset/2` would let an unrelated draft-era rule
  block a metrics refresh.
  """
  def automation_changeset(post, attrs) do
    cast(post, attrs, [:automation_state, :metrics, :metrics_updated_at])
  end

  @doc "Marks a post as successfully published."
  def published_changeset(post, x_post_ids) do
    permalink =
      case x_post_ids do
        [first | _] -> "https://x.com/i/status/#{first}"
        _ -> nil
      end

    change(post,
      status: "posted",
      x_post_ids: x_post_ids,
      permalink: permalink,
      published_at: DateTime.utc_now() |> DateTime.truncate(:second),
      error: nil,
      failed_at: nil
    )
  end

  @doc "Records a publishing failure so the Failed tab can show it."
  def failed_changeset(post, reason) do
    change(post,
      status: "failed",
      error: to_string(reason),
      failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      attempt_count: post.attempt_count + 1
    )
  end

  # Segments arrive from the composer as maps with string or atom keys.
  defp normalize_segments(changeset) do
    update_change(changeset, :segments, fn segments ->
      segments
      |> Enum.map(fn segment ->
        %{
          "text" => segment |> get_field_value("text") |> to_string() |> String.trim_trailing(),
          "media_ids" => segment |> get_field_value("media_ids") |> List.wrap()
        }
      end)
      # Trailing empty composer boxes shouldn't become empty tweets.
      |> Enum.reject(&(&1["text"] == "" and &1["media_ids"] == []))
    end)
  end

  defp get_field_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp validate_segments(changeset) do
    segments = get_field(changeset, :segments) || []
    status = get_field(changeset, :status)

    cond do
      # Drafts are allowed to be empty while the user is still typing.
      segments == [] and status == "draft" ->
        changeset

      segments == [] ->
        add_error(changeset, :segments, "must contain at least one post")

      true ->
        case Enum.find_index(segments, &(String.length(&1["text"]) > @max_segment_length)) do
          nil ->
            changeset

          index ->
            add_error(
              changeset,
              :segments,
              "post #{index + 1} is over #{@max_segment_length} characters"
            )
        end
    end
  end

  defp validate_scheduled_at(changeset) do
    case {get_field(changeset, :status), get_field(changeset, :scheduled_at)} do
      {"scheduled", nil} ->
        add_error(changeset, :scheduled_at, "is required to schedule a post")

      _ ->
        changeset
    end
  end

  defp validate_positive_automations(changeset) do
    Enum.reduce(@positive_automation_fields, changeset, fn field, changeset ->
      validate_number(changeset, field, greater_than: 0)
    end)
  end

  # A plug without text would post nothing once the like threshold hits, so
  # the two fields must arrive together.
  defp validate_auto_plug_text(changeset) do
    case {get_field(changeset, :auto_plug_likes), get_field(changeset, :auto_plug_text)} do
      {likes, text} when not is_nil(likes) and (is_nil(text) or text == "") ->
        add_error(changeset, :auto_plug_text, "is required when auto plug likes is set")

      _ ->
        changeset
    end
  end

  defp validate_media(changeset) do
    segments = get_field(changeset, :segments) || []

    cond do
      index = Enum.find_index(segments, &(length(&1["media_ids"]) > @max_media_per_segment)) ->
        add_error(
          changeset,
          :segments,
          "post #{index + 1} has more than #{@max_media_per_segment} attachments"
        )

      index = Enum.find_index(segments, &mixed_gif?/1) ->
        # X accepts four still images but a GIF must occupy the media slot
        # alone, so accepting the mixture would guarantee a paid API failure.
        add_error(changeset, :segments, "post #{index + 1} must attach a GIF on its own")

      true ->
        changeset
    end
  end

  defp mixed_gif?(%{"media_ids" => media_ids}) do
    length(media_ids) > 1 and Enum.any?(media_ids, &SuperX.Media.gif?/1)
  end

  @doc "Plain text of the whole thread, for previews and search."
  def preview_text(%__MODULE__{segments: segments}) do
    segments |> Enum.map_join("\n\n", & &1["text"]) |> String.trim()
  end
end
