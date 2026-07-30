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
  attr :rest, :global

  slot :meta, doc: "attribution or source line, above the actions"
  slot :actions
  slot :footer, doc: "engagement figures or status"

  def post(assigns) do
    ~H"""
    <article class={["post", @class]} {@rest}>
      <div class="post-thread">
        <div :for={{segment, index} <- Enum.with_index(@segments)} class="post-seg">
          <div class="flex gap-2.5">
            <Layouts.avatar src={@author[:avatar_url]} size="size-6" class="mt-0.5" />

            <div class="min-w-0 flex-1">
              <p :if={index == 0} class="post-head text-[13px]">
                <span class="post-name truncate">{@author[:name] || @author[:handle]}</span>
                <span class="post-handle truncate">@{@author[:handle]}</span>
              </p>
              <p
                class={["post-body", index == 0 && "mt-0.5"]}
                data-clamp={@clamp && "true"}
                style={@clamp && "--clamp-lines: #{@clamp}"}
              >{segment["text"]}</p>
            </div>
          </div>
        </div>
      </div>

      <%!-- Meta and actions are stacked rather than justified apart. Side
            by side they fit on one line for some cards and wrap for others
            depending on how long the attribution runs, so a column of cards
            ends up with a ragged, accidental-looking footer. Stacking costs
            one thin line and is the same on every card. --%>
      <div :if={@meta != [] or @footer != []} class="mt-3 flex items-center gap-4">
        <span :if={@meta != []} class="text-[11px] text-faint">{render_slot(@meta)}</span>
        <span :if={@footer != []}>{render_slot(@footer)}</span>
      </div>

      <div :if={@actions != []} class="mt-2 flex flex-wrap items-center gap-4 text-xs">
        {render_slot(@actions)}
      </div>
    </article>
    """
  end

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
      <span :if={@likes}><b>{compact(@likes)}</b> likes</span>
      <span :if={@reposts}>{compact(@reposts)} reposts</span>
      <span :if={@replies}>{compact(@replies)} replies</span>
      <span :if={@impressions}>{compact(@impressions)} views</span>
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
  def segments(%CorpusPost{text: text}), do: [%{"text" => text}]

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
