defmodule SuperXWeb.PostComponents do
  @moduledoc """
  Rendering an X post as a post.

  The rest of the app follows the editorial constitution — hairlines and
  air, no containers. These components are the deliberate exception: a
  post carries an author and social proof, and reading it means judging
  *whose* it is and how it landed, which a flat row cannot express.

  Everything a post appears in goes through here, so a change to how a
  post looks is one edit rather than five.
  """

  use Phoenix.Component
  use SuperXWeb, :verified_routes

  import SuperXWeb.CoreComponents, only: [icon: 1]

  alias SuperX.Content.{CorpusPost, Generation, Post}
  alias SuperXWeb.Layouts

  @doc """
  A post card.

  `author` is a map with `:name`, `:handle`, and `:avatar_url`. `segments`
  is the list of `%{"text" => ...}` maps used everywhere else in the app,
  so a thread renders as connected segments rather than a joined blob.
  """
  attr :author, :map, required: true
  attr :segments, :list, required: true
  attr :class, :any, default: nil
  attr :clamp, :integer, default: nil, doc: "cap the body at N lines, for scannable lists"
  attr :timestamp, :string, default: nil, doc: "already-formatted age, shown on the head line"
  attr :compact, :boolean, default: false, doc: "denser card for previews and sidebars"
  attr :media_uploads, :map, default: %{}
  attr :media_owner_id, :string, default: nil
  attr :media_remove_event, :string, default: nil
  attr :media_cancel_event, :string, default: nil
  attr :rest, :global

  slot :meta, doc: "attribution or source line, above the actions"
  slot :actions
  slot :footer, doc: "engagement figures or status"

  def post(assigns) do
    ~H"""
    <article class={["post", @compact && "post-compact", @class]} {@rest}>
      <div class="post-thread">
        <div :for={{segment, index} <- Enum.with_index(@segments)} class="post-seg">
          <% upload = Map.get(@media_uploads, index) %>
          <div class="flex gap-[var(--post-gutter)]">
            <Layouts.avatar
              src={@author[:avatar_url]}
              name={@author[:name] || @author[:handle]}
              size="post-avatar"
            />

            <div class="min-w-0 flex-1">
              <p :if={index == 0} class="post-head">
                <span class="post-name truncate">{@author[:name] || @author[:handle]}</span>
                <span class="post-handle truncate">@{@author[:handle]}</span>
                <span :if={@timestamp} class="post-time">{@timestamp}</span>
              </p>
              <%!-- `phx-no-format` is load-bearing, not a style preference.
                    This element is `white-space: pre-wrap` so the author's
                    own line breaks survive — which means the template's
                    whitespace survives too. Left to itself the formatter
                    puts `{segment["text"]}` on its own indented line, and
                    every post in the product renders with a blank first
                    line and a stray indent. The tag must close onto the
                    interpolation, so the formatter is told to keep out. --%>
              <p
                class={["post-body", index == 0 && "mt-1"]}
                data-clamp={@clamp && "true"}
                style={@clamp && "--clamp-lines: #{@clamp}"}
                phx-no-format
              >{segment["text"]}</p>
              <.post_media
                media_ids={segment["media_ids"] || []}
                media={segment["media"] || []}
                upload={upload}
                owner_id={@media_owner_id}
                segment_index={index}
                remove_event={@media_remove_event}
                cancel_event={@media_cancel_event}
              />
            </div>
          </div>
        </div>
      </div>

      <%!-- Attribution sits left, figures right, on one line above the
            hairline. They were previously stacked because a justified row
            wrapped unevenly between cards — but that was with the figures
            spelled out in words. As glyphs they are short and fixed-width,
            so the row holds its shape down a column. --%>
      <div :if={@meta != [] or @footer != []} class="post-foot">
        <span :if={@meta != []} class="post-meta">{render_slot(@meta)}</span>
        <span :if={@footer != []} class="ml-auto">{render_slot(@footer)}</span>
      </div>

      <div :if={@actions != []} class="post-actions">
        {render_slot(@actions)}
      </div>
    </article>
    """
  end

  @doc "Attached post media, shared by cards and editable previews."
  attr :media_ids, :list, default: []
  attr :media, :list, default: []
  attr :upload, :any, default: nil
  attr :owner_id, :string, default: nil
  attr :segment_index, :integer, default: nil
  attr :remove_event, :string, default: nil
  attr :cancel_event, :string, default: nil

  def post_media(assigns) do
    entries = if assigns.upload, do: assigns.upload.entries, else: []
    media = Enum.filter(assigns.media, &(media_url(&1) not in [nil, ""]))
    count = length(assigns.media_ids) + length(media) + length(entries)

    assigns =
      assigns
      |> assign(:entries, entries)
      |> assign(:media, media)
      |> assign(:count, count)
      |> assign(:can_add?, can_add_media?(assigns.media_ids, entries, count))

    ~H"""
    <div :if={@count > 0} class="post-media-grid" data-count={@count}>
      <div :for={item <- @media} class="post-media-item">
        <img
          src={media_url(item)}
          alt={media_alt(item)}
          class="post-media-image"
          loading="lazy"
        />
      </div>

      <div :for={media_id <- @media_ids} class="post-media-item">
        <img
          src={SuperX.Media.url(media_id)}
          alt="Attached post media"
          class="post-media-image"
        />
        <button
          :if={@remove_event}
          type="button"
          phx-click={@remove_event}
          phx-value-owner={@owner_id}
          phx-value-index={@segment_index}
          phx-value-media-id={media_id}
          class="post-media-remove"
          aria-label="Remove attachment"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>

      <div :for={entry <- @entries} class="post-media-item">
        <.live_img_preview entry={entry} class="post-media-image" />
        <span
          :if={!entry.done?}
          class="nb-mono absolute bottom-2 left-2 bg-card px-1.5 py-0.5 text-[10px] text-muted-foreground"
        >
          {entry.progress}%
        </span>
        <button
          :if={@cancel_event}
          type="button"
          phx-click={@cancel_event}
          phx-value-upload={@upload.name}
          phx-value-ref={entry.ref}
          class="post-media-remove"
          aria-label="Cancel attachment"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
      </div>
    </div>

    <div :if={@upload} class="mt-2">
      <label :if={@can_add?} class="act inline-flex cursor-pointer items-center gap-1.5 text-xs">
        <.icon name="hero-photo" class="size-4" /> Add image or GIF
        <.live_file_input upload={@upload} class="sr-only" />
      </label>

      <p
        :for={error <- upload_errors(@upload)}
        class="mt-1 text-[11px] text-destructive"
      >
        {upload_error(error)}
      </p>
      <p
        :for={entry <- @entries}
        :if={upload_errors(@upload, entry) != []}
        class="mt-1 text-[11px] text-destructive"
      >
        {entry.client_name}: {upload_errors(@upload, entry) |> Enum.map_join(", ", &upload_error/1)}
      </p>
    </div>
    """
  end

  defp can_add_media?(media_ids, entries, count) do
    count < Post.max_media_per_segment() and
      not Enum.any?(media_ids, &SuperX.Media.gif?/1) and
      not Enum.any?(entries, &(&1.client_type == "image/gif"))
  end

  defp media_url(item), do: item["url"] || item[:url]

  defp media_alt(item) do
    case item["type"] || item[:type] do
      "video" -> "Attached video preview"
      "animated_gif" -> "Attached GIF preview"
      _ -> "Attached post media"
    end
  end

  defp upload_error(:too_large), do: "Each attachment must be 5 MB or smaller."
  defp upload_error(:too_many_files), do: "A post can carry up to four images."
  defp upload_error(:not_accepted), do: "Use a JPEG, PNG, WebP or GIF."
  defp upload_error(_error), do: "That attachment could not be uploaded."

  @doc """
  Engagement figures, always in the same order and the same units so two
  cards can be compared at a glance.
  """
  attr :likes, :integer, default: nil
  attr :reposts, :integer, default: nil
  attr :replies, :integer, default: nil
  attr :impressions, :integer, default: nil

  def metrics(assigns) do
    ~H"""
    <div class="metrics">
      <span :if={@likes} title={"#{@likes} likes"}>
        <.icon name="hero-heart" class="size-3" /><b>{compact(@likes)}</b>
      </span>
      <span :if={@reposts} title={"#{@reposts} reposts"}>
        <.icon name="hero-arrow-path-rounded-square" class="size-3" />{compact(@reposts)}
      </span>
      <span :if={@replies} title={"#{@replies} replies"}>
        <.icon name="hero-chat-bubble-oval-left" class="size-3" />{compact(@replies)}
      </span>
      <span :if={@impressions} title={"#{@impressions} views"}>
        <.icon name="hero-chart-bar" class="size-3" />{compact(@impressions)}
      </span>
    </div>
    """
  end

  @doc """
  Character budget as a ring. Fills toward the limit, warms to ember close
  to it, and turns destructive past it — legible without reading a number.
  """
  attr :count, :integer, required: true
  attr :limit, :integer, default: 280

  def char_ring(assigns) do
    pct = min(assigns.count / assigns.limit, 1.0)

    color =
      cond do
        assigns.count > assigns.limit -> "var(--destructive)"
        assigns.count > assigns.limit * 0.9 -> "var(--primary)"
        true -> "var(--muted-foreground)"
      end

    assigns = assign(assigns, pct: round(pct * 100), color: color)

    ~H"""
    <span class="flex items-center gap-2">
      <span
        class="char-ring"
        style={"--ring-pct: #{@pct}%; --ring-color: #{@color}"}
        role="img"
        aria-label={"#{@count} of #{@limit} characters used"}
      />
      <span
        :if={@count > @limit * 0.8}
        class={[
          "nb-mono text-[11px]",
          if(@count > @limit, do: "text-destructive", else: "text-faint")
        ]}
      >
        {@limit - @count}
      </span>
    </span>
    """
  end

  @doc "Author map for one of the user's own connected accounts."
  def author(%{handle: handle} = account) do
    %{name: account.display_name, handle: handle, avatar_url: account.avatar_url}
  end

  @doc "Author map for a post from the corpus."
  def corpus_author(%CorpusPost{} = post) do
    %{name: post.author_name, handle: post.author_handle, avatar_url: post.author_avatar_url}
  end

  @doc "Permalink to a corpus post on X."
  def corpus_url(%CorpusPost{author_handle: handle, x_post_id: id}),
    do: "https://x.com/#{handle}/status/#{id}"

  @doc "Segments for anything that carries them, normalised to a list."
  def segments(%Generation{segments: segments}), do: normalize(segments)
  def segments(%Post{segments: segments}), do: normalize(segments)
  def segments(%CorpusPost{text: text, media: media}), do: [%{"text" => text, "media" => media}]

  defp normalize([]), do: [%{"text" => ""}]
  defp normalize(segments), do: segments

  @doc "Compact figure formatting shared by every metric on every screen."
  def compact(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def compact(n) when n >= 10_000, do: "#{round(n / 1_000)}K"
  def compact(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  def compact(n), do: to_string(n)

  @doc "Coarse relative time — the exact minute never matters on these screens."
  def ago(nil), do: ""

  def ago(datetime) do
    case DateTime.diff(DateTime.utc_now(), datetime, :second) do
      s when s < 3600 -> "just now"
      s when s < 86_400 -> "#{div(s, 3600)}h ago"
      s when s < 172_800 -> "yesterday"
      s when s < 2_592_000 -> "#{div(s, 86_400)}d ago"
      s -> "#{div(s, 2_592_000)}mo ago"
    end
  end
end
