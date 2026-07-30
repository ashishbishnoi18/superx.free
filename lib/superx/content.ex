defmodule SuperX.Content do
  @moduledoc """
  Posts, the publishing queue, schedule slots, voice profiles, and the
  Ready to Post shelf.
  """

  import Ecto.Query

  alias SuperX.Accounts.{User, XAccount}
  alias SuperX.Content.{Generation, Post, ScheduleSlot, VoiceProfile}
  alias SuperX.Repo

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

  def get_post(%User{} = user, id) do
    Repo.get_by(Post, id: id, user_id: user.id)
  end

  @doc "Posts for one account in one lifecycle state."
  def list_posts(%XAccount{} = account, status, opts \\ []) do
    Post
    |> where(x_account_id: ^account.id, status: ^status)
    |> order_by(^order_for(status))
    |> limit(^(opts[:limit] || 100))
    |> Repo.all()
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

    Map.new(Post.statuses(), &{&1, Map.get(counts, &1, 0)})
  end

  def create_post(%User{} = user, %XAccount{} = account, attrs) do
    attrs = attrs |> Map.put(:user_id, user.id) |> Map.put(:x_account_id, account.id)

    %Post{}
    |> Post.changeset(attrs)
    |> Repo.insert()
  end

  def update_post(%Post{} = post, attrs) do
    post |> Post.changeset(attrs) |> Repo.update()
  end

  def change_post(%Post{} = post, attrs \\ %{}), do: Post.changeset(post, attrs)

  def delete_post(%Post{} = post), do: Repo.delete(post)

  @doc """
  Schedules a post into the next free slot, or at `at` when given.

  Returns `{:error, :no_slots}` when the account has no enabled slots,
  which the UI turns into a prompt to set some up.
  """
  def schedule_post(%Post{} = post, opts \\ []) do
    account = Repo.get!(XAccount, post.x_account_id)
    user = Repo.get!(User, post.user_id)

    case opts[:at] || next_open_slot_at(account, user) do
      nil ->
        {:error, :no_slots}

      %DateTime{} = at ->
        post
        |> Post.changeset(%{status: "scheduled", scheduled_at: DateTime.truncate(at, :second)})
        |> Repo.update()
    end
  end

  @doc "Moves a scheduled post back to drafts."
  def unschedule_post(%Post{} = post) do
    post |> Post.changeset(%{status: "draft", scheduled_at: nil}) |> Repo.update()
  end

  @doc """
  The next slot time with nothing already scheduled in it.

  Walks forward through the recurring weekly grid in the user's local
  time, skipping slots that are in the past or already taken, up to eight
  weeks out.
  """
  @spec next_open_slot_at(XAccount.t(), User.t()) :: DateTime.t() | nil
  def next_open_slot_at(%XAccount{} = account, %User{} = user) do
    slots = account |> list_slots() |> Enum.filter(& &1.enabled)

    if slots == [] do
      nil
    else
      taken = scheduled_times(account)
      now = DateTime.utc_now()

      account
      |> upcoming_slot_times(slots, user.timezone, now)
      |> Enum.find(&(&1 not in taken))
    end
  end

  defp scheduled_times(%XAccount{} = account) do
    Post
    |> where(x_account_id: ^account.id, status: "scheduled")
    |> select([p], p.scheduled_at)
    |> Repo.all()
    |> MapSet.new()
  end

  # Every slot occurrence over the next 8 weeks, in chronological order.
  defp upcoming_slot_times(_account, slots, timezone, now) do
    today = now |> DateTime.shift_zone!(timezone, Tz.TimeZoneDatabase) |> DateTime.to_date()

    0..55
    |> Enum.flat_map(fn offset ->
      date = Date.add(today, offset)
      dow = Date.day_of_week(date, :sunday) - 1

      slots
      |> Enum.filter(&(&1.day_of_week == dow))
      |> Enum.flat_map(fn slot ->
        case DateTime.new(date, slot.time, timezone, Tz.TimeZoneDatabase) do
          {:ok, dt} ->
            [dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)]

          # Skip times that don't exist on a DST spring-forward day.
          _ ->
            []
        end
      end)
    end)
    |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
    |> Enum.sort(DateTime)
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
  Returns a failed post to the queue for another attempt.

  Retries publish as soon as the next dispatcher tick runs rather than
  waiting for the original slot — that slot is in the past, and someone
  pressing "Retry" wants it to go out now. Posts that failed before ever
  being scheduled get a time too, so the retry isn't rejected for having
  none.
  """
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
    |> preload(:source_corpus_post)
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

  def get_generation(%User{} = user, id) do
    Generation |> Repo.get_by(id: id, user_id: user.id) |> Repo.preload(:source_corpus_post)
  end

  def create_generation(attrs) do
    %Generation{} |> Generation.changeset(attrs) |> Repo.insert()
  end

  def dismiss_generation(%Generation{} = generation) do
    generation |> Generation.changeset(%{status: "dismissed"}) |> Repo.update()
  end

  @doc """
  Turns a shelf item into a real draft and marks it used, so the same
  generation can't be accepted twice.
  """
  def accept_generation(%User{} = user, %Generation{} = generation) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:generation, Generation.changeset(generation, %{status: "used"}))
    |> Ecto.Multi.insert(:post, fn _ ->
      Post.changeset(%Post{}, %{
        user_id: user.id,
        x_account_id: generation.x_account_id,
        generation_id: generation.id,
        segments: generation.segments,
        source: "generated",
        status: "draft"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} -> {:ok, post}
      {:error, _step, reason, _} -> {:error, reason}
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
