defmodule SuperX.Engage do
  @moduledoc """
  The engagement loop: what's waiting on you, and what to say back.
  """

  import Ecto.Query

  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Engage.{Engagement, Feed, ReplyDraft}
  alias SuperX.Repo

  # --- Engagements ---------------------------------------------------------

  @doc """
  Inbox for one account.

  Ordered by priority rather than recency: the point of the screen is to
  answer the things worth answering, and a strict feed buries those under
  whatever arrived last.
  """
  def list_engagements(%XAccount{} = account, opts \\ []) do
    Engagement
    |> where(x_account_id: ^account.id)
    |> filter_kind(opts[:kind])
    |> where(status: ^(opts[:status] || "open"))
    |> order_by([e], desc: fragment("coalesce(?, 0)", e.priority), desc: e.posted_at)
    |> limit(^(opts[:limit] || 50))
    |> preload(reply_drafts: ^drafts_query())
    |> Repo.all()
  end

  defp drafts_query,
    do: from(d in ReplyDraft, where: d.status == "shelf", order_by: [desc: d.inserted_at])

  defp filter_kind(query, nil), do: query
  defp filter_kind(query, kind), do: where(query, kind: ^kind)

  def get_engagement(%XAccount{} = account, id) do
    Engagement
    |> Repo.get_by(id: id, x_account_id: account.id)
    |> Repo.preload(reply_drafts: drafts_query())
  end

  @doc "Counts per kind for the tab row, open items only."
  def counts(%XAccount{} = account) do
    counts =
      Engagement
      |> where(x_account_id: ^account.id, status: "open")
      |> group_by([e], e.kind)
      |> select([e], {e.kind, count(e.id)})
      |> Repo.all()
      |> Map.new()

    Map.put(counts, "all", counts |> Map.values() |> Enum.sum())
  end

  @doc """
  Inserts or refreshes a batch of engagements.

  Metrics are replaced on conflict because a mention keeps accruing likes
  after we first see it, but `status` is left alone — re-polling must not
  reopen something the user already dealt with.
  """
  def upsert_many(attrs_list) when is_list(attrs_list) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      attrs_list
      |> Enum.map(&build_row(&1, now))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.x_post_id)

    Repo.insert_all(Engagement, rows,
      on_conflict:
        {:replace,
         [:likes, :reposts, :replies, :author_followers, :priority, :priority_reason, :updated_at]},
      conflict_target: [:x_account_id, :x_post_id]
    )
  end

  defp build_row(attrs, now) do
    case Engagement.changeset(%Engagement{}, attrs) do
      %{valid?: true} = changeset ->
        engagement = Ecto.Changeset.apply_changes(changeset)

        engagement
        |> Map.take([
          :x_account_id,
          :feed_id,
          :kind,
          :status,
          :x_post_id,
          :conversation_id,
          :in_reply_to_x_post_id,
          :author_handle,
          :author_name,
          :author_avatar_url,
          :author_followers,
          :author_verified,
          :text,
          :lang,
          :likes,
          :reposts,
          :replies,
          :posted_at,
          :priority_reason
        ])
        |> Map.put(:priority, engagement.priority || Engagement.heuristic_priority(engagement))
        |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})

      _invalid ->
        nil
    end
  end

  def ignore(%Engagement{} = engagement) do
    engagement |> Engagement.changeset(%{status: "ignored"}) |> Repo.update()
  end

  def reopen(%Engagement{} = engagement) do
    engagement |> Engagement.changeset(%{status: "open"}) |> Repo.update()
  end

  @doc """
  Marks an engagement answered and links the reply we published.
  """
  def mark_replied(%Engagement{} = engagement, post_id) do
    engagement
    |> Ecto.Changeset.change(
      status: "replied",
      replied_post_id: post_id,
      replied_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.update()
  end

  @doc "The newest post id we've seen for an account, to poll incrementally."
  def latest_post_id(%XAccount{} = account, kind) do
    Engagement
    |> where(x_account_id: ^account.id, kind: ^kind)
    |> order_by(desc: :posted_at)
    |> limit(1)
    |> select([e], e.x_post_id)
    |> Repo.one()
  end

  # --- Reply drafts --------------------------------------------------------

  def create_draft(attrs) do
    %ReplyDraft{} |> ReplyDraft.changeset(attrs) |> Repo.insert()
  end

  def get_draft(%User{} = user, id) do
    ReplyDraft
    |> Repo.get_by(id: id, user_id: user.id)
    |> Repo.preload(:engagement)
  end

  def dismiss_draft(%ReplyDraft{} = draft) do
    draft |> ReplyDraft.changeset(%{status: "dismissed"}) |> Repo.update()
  end

  def use_draft(%ReplyDraft{} = draft) do
    draft |> ReplyDraft.changeset(%{status: "used"}) |> Repo.update()
  end

  # --- Feeds ---------------------------------------------------------------

  def list_feeds(%XAccount{} = account) do
    Feed
    |> where(x_account_id: ^account.id)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  def create_feed(%XAccount{} = account, attrs) do
    %Feed{}
    |> Feed.changeset(Map.put(attrs, :x_account_id, account.id))
    |> Repo.insert()
  end

  def delete_feed(%XAccount{} = account, id) do
    case Repo.get_by(Feed, id: id, x_account_id: account.id) do
      nil -> {:error, :not_found}
      feed -> Repo.delete(feed)
    end
  end

  def toggle_feed(%XAccount{} = account, id) do
    case Repo.get_by(Feed, id: id, x_account_id: account.id) do
      nil -> {:error, :not_found}
      feed -> feed |> Feed.changeset(%{enabled: not feed.enabled}) |> Repo.update()
    end
  end

  def touch_feed(%Feed{} = feed) do
    feed
    |> Feed.changeset(%{last_synced_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end

  @doc "Feeds due for a sync, oldest first."
  def feeds_due(within_minutes \\ 60) do
    cutoff = DateTime.utc_now() |> DateTime.add(-within_minutes * 60, :second)

    Feed
    |> where([f], f.enabled)
    |> where([f], is_nil(f.last_synced_at) or f.last_synced_at <= ^cutoff)
    |> order_by([f], asc_nulls_first: f.last_synced_at)
    |> preload(:x_account)
    |> Repo.all()
  end
end
