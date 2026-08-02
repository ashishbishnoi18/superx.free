defmodule SuperX.Workers.QueueDispatcherTest do
  use SuperX.DataCase, async: false

  import Oban.Testing
  import SuperX.Fixtures

  alias SuperX.{Accounts, Content}
  alias SuperX.Workers.{PublishPost, QueueDispatcher}

  setup do
    user_fixture()
  end

  test "enqueues each due post for immediate publish when jitter is off", %{
    user: user,
    account: account
  } do
    post = due_post(user, account)

    assert :ok = QueueDispatcher.perform(%Oban.Job{args: %{}})

    assert [job] = all_enqueued(repo: SuperX.Repo, worker: PublishPost)
    assert job.args == %{"post_id" => post.id}
    # No jitter: the job is due now, not pushed into the future.
    assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) != :gt
  end

  test "delays the publish job within the owner's jitter window", %{
    user: user,
    account: account
  } do
    {:ok, _user} = Accounts.update_settings(user, %{"queue_jitter_minutes" => 5})
    _post = due_post(user, account)

    before = DateTime.utc_now()

    # The draw is random in 1..300s, so sample several ticks: one unlucky
    # small draw must not fail the suite, but every draw must stay in range.
    for _ <- 1..5 do
      assert :ok = QueueDispatcher.perform(%Oban.Job{args: %{}})
    end

    jobs = all_enqueued(repo: SuperX.Repo, worker: PublishPost)
    assert length(jobs) == 5

    for job <- jobs do
      assert DateTime.diff(job.scheduled_at, before, :second) in 1..310
    end

    # Across five draws at least one lands meaningfully in the future — an
    # implementation that ignored jitter would schedule all five at once.
    assert Enum.any?(jobs, &(DateTime.diff(&1.scheduled_at, before, :second) > 30))
  end

  test "treats an unreadable jitter setting as no jitter", %{user: user, account: account} do
    {:ok, _user} = Accounts.update_settings(user, %{"queue_jitter_minutes" => "often"})
    _post = due_post(user, account)

    assert :ok = QueueDispatcher.perform(%Oban.Job{args: %{}})

    assert [job] = all_enqueued(repo: SuperX.Repo, worker: PublishPost)
    assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) != :gt
  end

  defp due_post(user, account) do
    {:ok, post} =
      Content.create_post(user, account, %{segments: [%{"text" => "due"}], status: "draft"})

    {:ok, post} =
      Content.schedule_post(post,
        at: DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
      )

    post
  end
end
