defmodule SuperX.WorkersTest do
  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.Workers

  setup do
    user_fixture()
  end

  describe "content worker configuration" do
    test "requires a product brief and bounds the paid batch", %{user: user, account: account} do
      assert {:error, changeset} =
               Workers.create_content_worker(user, account, %{
                 name: "Product notes",
                 topic_source: "products",
                 batch_size: 21
               })

      assert "can't be blank" in errors_on(changeset).product_context
      assert "must be less than or equal to 20" in errors_on(changeset).batch_size
    end

    test "normalises schedule fields that the selected cadence cannot use", %{
      user: user,
      account: account
    } do
      assert {:ok, daily} =
               Workers.create_content_worker(user, account, %{
                 name: "Daily voice",
                 topic_source: "voice",
                 batch_size: 2,
                 cadence: "daily",
                 schedule_day: 5,
                 schedule_time: ~T[09:15:00]
               })

      assert daily.schedule_day == nil
      assert daily.schedule_time == ~T[09:15:00]

      assert {:ok, manual} =
               Workers.update_content_worker(daily, %{
                 cadence: nil,
                 schedule_day: 4,
                 schedule_time: ~T[12:00:00]
               })

      assert manual.schedule_day == nil
      assert manual.schedule_time == nil
    end

    test "scopes lookups to both the owner and selected account", %{
      user: user,
      account: account
    } do
      other = user_fixture()
      {:ok, worker} = worker_fixture(user, account)

      assert Workers.get_content_worker(user, account, worker.id) == worker
      assert Workers.get_content_worker(other.user, other.account, worker.id) == nil

      assert {:error, :not_found} =
               Workers.create_content_worker(user, other.account, %{
                 name: "Wrong account",
                 topic_source: "voice",
                 batch_size: 1
               })
    end

    test "a disabled worker still suppresses the legacy nightly top-up", %{
      user: user,
      account: account
    } do
      refute Workers.configured_for_account?(account)

      assert {:ok, _worker} = worker_fixture(user, account, %{enabled: false})
      assert Workers.configured_for_account?(account)
    end
  end

  describe "local-time cadence" do
    test "a daily worker becomes due after its local time and only once", %{
      user: user,
      account: account
    } do
      {:ok, user} = SuperX.Accounts.update_user(user, %{timezone: "Asia/Kolkata"})

      {:ok, worker} =
        worker_fixture(user, account, %{
          cadence: "daily",
          schedule_time: ~T[09:00:00]
        })

      worker = %{
        worker
        | user: user,
          inserted_at: ~U[2026-07-31 04:00:00Z]
      }

      refute Workers.due?(worker, ~U[2026-08-01 03:29:00Z])
      assert Workers.due?(worker, ~U[2026-08-01 03:31:00Z])

      worker = %{worker | last_run_at: ~U[2026-08-01 03:30:00Z]}
      refute Workers.due?(worker, ~U[2026-08-01 03:31:00Z])
    end

    test "does not backfill an occurrence from before the worker existed", %{
      user: user,
      account: account
    } do
      {:ok, worker} =
        worker_fixture(user, account, %{
          cadence: "weekly",
          schedule_day: 6,
          schedule_time: ~T[08:00:00]
        })

      worker = %{
        worker
        | user: user,
          inserted_at: ~U[2026-08-01 09:00:00Z]
      }

      refute Workers.due?(worker, ~U[2026-08-01 10:00:00Z])
    end

    test "manual and disabled workers are never due", %{user: user, account: account} do
      {:ok, manual} = worker_fixture(user, account)
      refute Workers.due?(%{manual | user: user}, DateTime.utc_now())

      {:ok, disabled} =
        worker_fixture(user, account, %{
          enabled: false,
          cadence: "daily",
          schedule_time: ~T[00:00:00]
        })

      refute Workers.due?(%{disabled | user: user}, DateTime.utc_now())
    end
  end

  defp worker_fixture(user, account, attrs \\ %{}) do
    defaults = %{
      name: "Voice ideas",
      topic_source: "voice",
      batch_size: 3,
      enabled: true
    }

    Workers.create_content_worker(user, account, Map.merge(defaults, attrs))
  end
end
