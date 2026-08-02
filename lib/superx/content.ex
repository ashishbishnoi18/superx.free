defmodule SuperX.Content do
  @moduledoc """
  Posts, the publishing queue, schedule slots, voice profiles, and the
  Ready to Post shelf.
  """

  import Ecto.Query

  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Content.{Generation, Post, ScheduleSlot, Slot, VoiceProfile}
  alias SuperX.{Media, Repo}

  # --- Voice profiles ------------------------------------------------------

  def get_voice_profile(%XAccount{} = account) do
    Repo.get_by(VoiceProfile, x_account_id: account.id)
  end

  def get_or_create_voice_profile(%XAccount{} = account) do
    case get_voice_profile(account) do
      nil ->
        %VoiceProfile{}
        |> VoiceProfile.changeset(%{x_account_id: account.id})
        |> Repo.insert()

      profile ->
        {:ok, profile}
    end
  end

  def update_voice_profile(%VoiceProfile{} = profile, attrs) do
    profile |> VoiceProfile.changeset(attrs) |> Repo.update()
  end

  def change_voice_profile(%VoiceProfile{} = profile, attrs \\ %{}) do
    VoiceProfile.changeset(profile, attrs)
  end

  # --- Schedule slots ------------------------------------------------------

  def list_slots(%XAccount{} = account) do
    ScheduleSlot
    |> where(x_account_id: ^account.id)
    |> order_by([s], asc: s.day_of_week, asc: s.time)
    |> Repo.all()
  end

  def create_slot(%XAccount{} = account, attrs) do
    %ScheduleSlot{}
    |> ScheduleSlot.changeset(Map.put(attrs, :x_account_id, account.id))
    |> Repo.insert()
  end

  def delete_slot(%XAccount{} = account, slot_id) do
    case Repo.get_by(ScheduleSlot, id: slot_id, x_account_id: account.id) do
      nil -> {:error, :not_found}
      slot -> Repo.delete(slot)
    end
  end

  def toggle_slot(%XAccount{} = account, slot_id) do
    case Repo.get_by(ScheduleSlot, id: slot_id, x_account_id: account.id) do
      nil -> {:error, :not_found}
      slot -> slot |> ScheduleSlot.changeset(%{enabled: not slot.enabled}) |> Repo.update()
    end
  end

  # --- Posts ---------------------------------------------------------------

  def get_post(%User{id: user_id}, %XAccount{id: account_id, user_id: user_id}, id) do
    Repo.get_by(Post, id: id, user_id: user_id, x_account_id: account_id)
  end

  def get_post(%User{}, %XAccount{}, _id), do: nil

  @doc """
  Posts for one account in one lifecycle state.

  Pass `tag: "ai"` to keep only posts carrying that tag.
  """
  def list_posts(%XAccount{} = account, status, opts \\ []) do
    Post
    |> where(x_account_id: ^account.id, status: ^status)
    |> with_tag(opts[:tag])
    |> order_by(^order_for(status))
    |> limit(^(opts[:limit] || 100))
    |> Repo.all()
  end

  defp with_tag(query, tag) when tag in [nil, ""], do: query
  defp with_tag(query, tag), do: where(query, [p], fragment("? = ANY(?)", ^tag, p.tags))

  @doc "Every tag used on the account's posts, sorted — for filter menus."
  def list_tags(%XAccount{} = account) do
    Post
    |> where(x_account_id: ^account.id)
    |> select([p], fragment("unnest(?)", p.tags))
    |> Repo.all()
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Upcoming work reads best soonest-first; history reads newest-first.
  defp order_for("scheduled"), do: [asc: :scheduled_at]
  defp order_for("posted"), do: [desc: :published_at]
  defp order_for("failed"), do: [desc: :failed_at]
  defp order_for(_), do: [desc: :updated_at]

  @doc "How many posts sit in each tab, for the tab counters."
  def post_counts(%XAccount{} = account) do
    counts =
      Post
      |> where(x_account_id: ^account.id)
      |> group_by([p], p.status)
      |> select([p], {p.status, count(p.id)})
      |> Repo.all()
      |> Map.new()

    counts = Map.new(Post.statuses(), &{&1, Map.get(counts, &1, 0)})

    # Publishing is the active phase of scheduled work, not a fifth place
    # the user can navigate to. Keep it in the Scheduled counter while X is
    # accepting the request so the row and tab count do not briefly vanish.
    Map.update!(counts, "scheduled", &(&1 + counts["publishing"]))
  end

  def create_post(
        %User{id: user_id},
        %XAccount{id: account_id, user_id: user_id},
        attrs
      ) do
    %Post{user_id: user_id, x_account_id: account_id}
    |> post_changeset(attrs)
    |> Repo.insert()
  end

  def create_post(%User{}, %XAccount{}, _attrs), do: {:error, :account_mismatch}

  def update_post(%Post{} = post, attrs) do
    post |> post_changeset(attrs) |> Repo.update()
  end

  def delete_post(%Post{} = post), do: Repo.delete(post)

  @doc """
  Schedules a post into the next free slot, or at `at` when given.

  Returns `{:error, :no_slots}` when the account has no enabled slots and
  `{:error, :slot_taken}` when an explicit time has already been claimed.
  """
  def schedule_post(%Post{} = post, opts \\ []) do
    account = Repo.get!(XAccount, post.x_account_id)
    user = Repo.get!(User, post.user_id)
    requested_at = opts[:at]

    Repo.transaction(fn ->
      lock_queue(account.id)

      case requested_at || next_open_slot_at(account, user) do
        nil ->
          Repo.rollback(:no_slots)

        %DateTime{} = at ->
          at = DateTime.truncate(at, :second)

          if requested_at && scheduled_at_taken?(account.id, post.id, at) do
            Repo.rollback(:slot_taken)
          else
            post
            |> Post.changeset(%{status: "scheduled", scheduled_at: at})
            |> Repo.update()
            |> unwrap_transaction()
          end
      end
    end)
  end

  defp unwrap_transaction({:ok, value}), do: value
  defp unwrap_transaction({:error, reason}), do: Repo.rollback(reason)

  defp lock_queue(account_id) do
    # Scheduling can arrive from LiveViews, Ask, and workers at once. A
    # per-account transaction lock makes "next opening" a claim rather
    # than two readers choosing the same apparently empty time.
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["superx.queue:#{account_id}"])
  end

  defp scheduled_at_taken?(account_id, post_id, at) do
    Post
    |> where([queued], queued.x_account_id == ^account_id and queued.status == "scheduled")
    |> where([queued], queued.scheduled_at == ^at and queued.id != ^post_id)
    |> Repo.exists?()
  end

  defp scheduled_at_taken?(account_id, at) do
    Post
    |> where([queued], queued.x_account_id == ^account_id and queued.status == "scheduled")
    |> where([queued], queued.scheduled_at == ^at)
    |> Repo.exists?()
  end

  defp insert_scheduled_generation(user, generation, at) do
    Repo.transaction(fn ->
      lock_queue(generation.x_account_id)

      generation =
        Repo.get_by(
          Generation,
          id: generation.id,
          user_id: user.id,
          x_account_id: generation.x_account_id,
          status: "shelf"
        ) || Repo.rollback(:not_on_shelf)

      if scheduled_at_taken?(generation.x_account_id, at) do
        Repo.rollback(:slot_taken)
      end

      generation
      |> Generation.changeset(%{status: "used"})
      |> Repo.update()
      |> unwrap_transaction()

      %Post{
        user_id: user.id,
        x_account_id: generation.x_account_id,
        generation_id: generation.id
      }
      |> post_changeset(%{
        segments: generation.segments,
        source: "generated",
        status: "scheduled",
        scheduled_at: at
      })
      |> Repo.insert()
      |> unwrap_transaction()
    end)
  end

  @doc """
  Moves a shelf item directly into one known opening.

  The shelf update and post insert share the queue lock and transaction, so
  a stale opening cannot consume a generation or create two posts at the
  same time.
  """
  def accept_generation_into_slot(
        %User{} = user,
        %Generation{status: "shelf"} = generation,
        %DateTime{} = at
      ) do
    insert_scheduled_generation(user, generation, DateTime.truncate(at, :second))
  end

  def accept_generation_into_slot(%User{}, %Generation{}, %DateTime{}) do
    {:error, :not_on_shelf}
  end

  @doc "Moves a scheduled post back to drafts."
  def unschedule_post(%Post{} = post) do
    query =
      from(p in Post,
        where: p.id == ^post.id and p.status == "scheduled",
        select: p
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.update_all(query,
           set: [status: "draft", scheduled_at: nil, updated_at: now]
         ) do
      {1, [updated]} -> {:ok, updated}
      {0, _} -> {:error, :not_scheduled}
    end
  end

  @doc """
  The next slot time with nothing already scheduled in it.

  Walks forward through the recurring weekly grid in the user's local
  time, skipping slots that are in the past or already taken, up to eight
  weeks out.
  """
  @spec next_open_slot_at(XAccount.t(), User.t()) :: DateTime.t() | nil
  def next_open_slot_at(%XAccount{} = account, %User{} = user) do
    account
    |> Slot.upcoming(user, weeks: 8)
    |> Enum.find_value(fn
      %{post: nil, at: at} -> at
      _occurrence -> nil
    end)
  end

  @doc "Scheduled posts that are due, for the dispatcher."
  def list_due_posts(now \\ DateTime.utc_now(), limit \\ 200) do
    Post
    |> where([p], p.status == "scheduled" and p.scheduled_at <= ^now)
    |> order_by(asc: :scheduled_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Atomically claims a post for publishing.

  The status guard means a post already picked up by another dispatcher
  tick is skipped rather than published twice.
  """
  def claim_for_publishing(post_id) do
    query =
      from(p in Post, where: p.id == ^post_id and p.status == "scheduled", select: p)

    case Repo.update_all(query, set: [status: "publishing"], inc: [attempt_count: 1]) do
      {1, [post]} -> {:ok, post}
      {0, _} -> {:error, :already_claimed}
    end
  end

  def mark_published(%Post{} = post, x_post_ids) do
    post |> Post.published_changeset(x_post_ids) |> Repo.update()
  end

  def mark_failed(%Post{} = post, reason) do
    post |> Post.failed_changeset(reason) |> Repo.update()
  end

  @doc """
  Merges new keys into a post's automation state and persists them.

  Workers record what has fired one marker at a time; merging here keeps a
  stale full-map write from erasing another automation's marker.
  """
  def update_automation_state(%Post{} = post, state) when is_map(state) do
    post
    |> Post.automation_changeset(%{automation_state: Map.merge(post.automation_state, state)})
    |> Ecto.Changeset.optimistic_lock(:automation_version)
    |> Repo.update()
  end

  @automation_actions ~w(retweet unretweet plug delete)

  @doc "Durably claims one external automation action before it reaches X."
  def claim_automation_action(%Post{} = post, action, %DateTime{} = now)
      when action in @automation_actions do
    state = post.automation_state || %{}

    if action_finished?(state, action) or automation_claimed?(state) do
      {:error, :already_claimed}
    else
      state = Map.put(state, claim_marker(action), DateTime.to_iso8601(now))
      optimistic_automation_update(post, state)
    end
  end

  @doc "Records a claimed action as complete without opening a duplicate-execution window."
  def complete_automation_action(%Post{} = post, action, %DateTime{} = now)
      when action in @automation_actions do
    state =
      (post.automation_state || %{})
      |> Map.delete(claim_marker(action))
      |> Map.put(done_marker(action), DateTime.to_iso8601(now))

    optimistic_automation_update(post, state)
  end

  @doc "Records a terminal provider rejection for a claimed automation."
  def fail_automation_action(%Post{} = post, action, reason) when action in @automation_actions do
    state =
      (post.automation_state || %{})
      |> Map.delete(claim_marker(action))
      |> Map.put("failed_#{action}", reason)

    optimistic_automation_update(post, state)
  end

  @doc "Releases a claim after a provider response proves no side effect occurred."
  def release_automation_action(%Post{} = post, action) when action in @automation_actions do
    state = Map.delete(post.automation_state || %{}, claim_marker(action))
    optimistic_automation_update(post, state)
  end

  defp optimistic_automation_update(post, state) do
    post
    |> Post.automation_changeset(%{automation_state: state})
    |> Ecto.Changeset.optimistic_lock(:automation_version)
    |> Repo.update(stale_error_field: :automation_state)
    |> case do
      {:error, changeset} ->
        if changeset.errors[:automation_state],
          do: {:error, :already_claimed},
          else: {:error, changeset}

      result ->
        result
    end
  end

  defp action_finished?(state, action) do
    not is_nil(state[done_marker(action)]) or not is_nil(state["failed_#{action}"])
  end

  defp automation_claimed?(state) do
    Enum.any?(state, fn {key, _value} -> String.starts_with?(key, "claimed_") end)
  end

  defp claim_marker(action), do: "claimed_#{action}_at"
  defp done_marker("retweet"), do: "retweeted_at"
  defp done_marker("unretweet"), do: "unretweeted_at"
  defp done_marker("plug"), do: "plugged_at"
  defp done_marker("delete"), do: "deleted_at"

  @doc "Stores the latest metrics pulled from X for a post."
  def update_metrics(%Post{} = post, metrics) when is_map(metrics) do
    post
    |> Post.automation_changeset(%{
      metrics: metrics,
      metrics_updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  @doc """
  Returns a failed post to the queue for another attempt.

  Retries publish as soon as the next dispatcher tick runs rather than
  waiting for the original slot — that slot is in the past, and someone
  pressing "Retry" wants it to go out now. Posts that failed before ever
  being scheduled get a time too, so the retry isn't rejected for having
  none.
  """
  # Retrying a partial thread would publish its first segments twice. The
  # surviving ids are the durable evidence that this is a manual recovery,
  # not an ordinary retry.
  def retry_post(%Post{status: "failed", x_post_ids: [_ | _]}),
    do: {:error, :partial_publish}

  def retry_post(%Post{status: "failed"} = post) do
    post
    |> Post.changeset(%{
      status: "scheduled",
      scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Ecto.Changeset.put_change(:error, nil)
    |> Ecto.Changeset.put_change(:failed_at, nil)
    |> Repo.update()
  end

  def retry_post(_post), do: {:error, :not_failed}

  # --- Ready to Post shelf -------------------------------------------------

  def list_shelf(%XAccount{} = account, opts \\ []) do
    Generation
    |> where(x_account_id: ^account.id, status: "shelf")
    |> then(fn q -> if opts[:kind], do: where(q, kind: ^opts[:kind]), else: q end)
    |> order_by([g], desc: g.score, desc: g.inserted_at)
    |> limit(^(opts[:limit] || 60))
    |> then(fn query ->
      if Keyword.get(opts, :preload_source, true) do
        preload(query, :source_corpus_post)
      else
        query
      end
    end)
    |> Repo.all()
  end

  def shelf_counts(%XAccount{} = account) do
    counts =
      Generation
      |> where(x_account_id: ^account.id, status: "shelf")
      |> group_by([g], g.kind)
      |> select([g], {g.kind, count(g.id)})
      |> Repo.all()
      |> Map.new()

    Map.put(counts, "all", counts |> Map.values() |> Enum.sum())
  end

  def get_generation(%User{id: user_id}, %XAccount{id: account_id, user_id: user_id}, id) do
    Generation
    |> Repo.get_by(id: id, user_id: user_id, x_account_id: account_id)
    |> Repo.preload(:source_corpus_post)
  end

  def get_generation(%User{}, %XAccount{}, _id), do: nil

  def create_generation(attrs) do
    %Generation{} |> Generation.changeset(attrs) |> generation_media_changeset() |> Repo.insert()
  end

  def update_generation(%Generation{} = generation, attrs) do
    generation |> Generation.changeset(attrs) |> generation_media_changeset() |> Repo.update()
  end

  def dismiss_generation(%Generation{} = generation) do
    generation |> Generation.changeset(%{status: "dismissed"}) |> Repo.update()
  end

  @doc """
  Turns a shelf item into a real draft and marks it used, so the same
  generation can't be accepted twice.
  """
  def accept_generation(%User{id: user_id} = user, %Generation{user_id: user_id} = generation) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:generation, Generation.changeset(generation, %{status: "used"}))
    |> Ecto.Multi.insert(:post, fn _ ->
      post_changeset(
        %Post{
          user_id: user.id,
          x_account_id: generation.x_account_id,
          generation_id: generation.id
        },
        %{
          segments: generation.segments,
          source: "generated",
          status: "draft"
        }
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} -> {:ok, post}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  def accept_generation(%User{}, %Generation{}), do: {:error, :not_found}

  defp post_changeset(post, attrs) do
    post |> Post.changeset(attrs) |> media_ownership_changeset(post.user_id, post.x_account_id)
  end

  defp generation_media_changeset(changeset) do
    media_ownership_changeset(
      changeset,
      Ecto.Changeset.get_field(changeset, :user_id),
      Ecto.Changeset.get_field(changeset, :x_account_id)
    )
  end

  defp media_ownership_changeset(changeset, user_id, account_id) do
    media_ids =
      changeset
      |> Ecto.Changeset.get_field(:segments, [])
      |> Enum.flat_map(fn
        segment when is_map(segment) -> Map.get(segment, "media_ids", [])
        _segment -> []
      end)

    if media_ids == [] or Media.owned_by?(user_id, account_id, media_ids) do
      changeset
    else
      Ecto.Changeset.add_error(changeset, :segments, "contains an unavailable attachment")
    end
  end

  @doc "How many shelf items an account is short of its target mix."
  def shelf_deficit(%XAccount{} = account, target_per_kind) do
    counts = shelf_counts(account)

    Map.new(target_per_kind, fn {kind, target} ->
      {kind, max(target - Map.get(counts, kind, 0), 0)}
    end)
  end
end
