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

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def max_segment_length, do: @max_segment_length

  @doc false
  def changeset(post, attrs) do
    post
    |> cast(attrs, [
      :user_id,
      :x_account_id,
      :generation_id,
      :status,
      :segments,
      :scheduled_at,
      :source,
      :reply_to_x_post_id,
      :tags
    ])
    |> validate_required([:user_id, :x_account_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> normalize_segments()
    |> validate_segments()
    |> validate_scheduled_at()
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

  @doc "Plain text of the whole thread, for previews and search."
  def preview_text(%__MODULE__{segments: segments}) do
    segments |> Enum.map_join("\n\n", & &1["text"]) |> String.trim()
  end

  @doc "True when the post is a thread rather than a single tweet."
  def thread?(%__MODULE__{segments: segments}), do: length(segments) > 1
end
