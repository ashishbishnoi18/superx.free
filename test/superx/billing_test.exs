defmodule SuperX.BillingTest do
  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.Billing
  alias SuperX.Billing.{Plan, Quota}

  setup do
    user_fixture()
  end

  describe "quotas" do
    test "creates a quota seeded from the plan limit", %{user: user} do
      quota = Billing.get_quota(user, "credits_month")

      assert quota.used == 0
      assert quota.limit == Plan.limit("free", :credits_month)
    end

    test "claims reduce the remaining balance", %{user: user} do
      assert {:ok, quota} = Billing.claim(user, "credits_month", 5)
      assert quota.used == 5
      assert Quota.remaining(quota) == Plan.limit("free", :credits_month) - 5
    end

    test "refuses a claim that would exceed the limit", %{user: user} do
      limit = Plan.limit("free", :credits_month)

      assert {:ok, _} = Billing.claim(user, "credits_month", limit)
      assert {:error, :quota_exceeded, details} = Billing.claim(user, "credits_month", 1)
      assert details.limit == limit
    end

    test "concurrent claims cannot oversell the limit", %{user: user} do
      limit = Plan.limit("free", :credits_month)
      parent = self()

      # Each task claims one credit. Exactly `limit` should succeed no
      # matter how the database interleaves them.
      results =
        1..(limit + 20)
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(SuperX.Repo, parent, self())
            Billing.claim(user, "credits_month", 1)
          end)
        end)
        |> Task.await_many(15_000)

      granted = Enum.count(results, &match?({:ok, _}, &1))

      assert granted == limit

      quota = Billing.get_quota(user, "credits_month")
      assert quota.used == limit
    end

    test "release returns units", %{user: user} do
      {:ok, _} = Billing.claim(user, "credits_month", 10)
      :ok = Billing.release(user, "credits_month", 4)

      assert Billing.get_quota(user, "credits_month").used == 6
    end

    test "rolls the window once it expires", %{user: user} do
      quota = Billing.get_quota(user, "credits_month")

      # Force the window into the past.
      quota
      |> Ecto.Changeset.change(
        used: 40,
        window_end: DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      rolled = Billing.get_quota(user, "credits_month")

      assert rolled.used == 0
      assert DateTime.compare(rolled.window_end, DateTime.utc_now()) == :gt
    end
  end

  describe "credits" do
    test "spending writes a ledger entry", %{user: user} do
      assert {:ok, _balance} = Billing.spend_credits(user, 3, "generation")

      assert [entry] = Billing.list_credit_entries(user)
      assert entry.delta == -3
      assert entry.reason == "generation"
    end

    test "spending past the limit leaves no ledger entry", %{user: user} do
      limit = Plan.limit("free", :credits_month)

      assert {:error, :quota_exceeded, _} = Billing.spend_credits(user, limit + 1, "generation")
      assert Billing.list_credit_entries(user) == []
      assert Billing.get_quota(user, "credits_month").used == 0
    end

    test "refund restores the balance and records it", %{user: user} do
      {:ok, _} = Billing.spend_credits(user, 5, "generation")
      {:ok, _} = Billing.refund_credits(user, 5)

      assert Billing.credit_balance(user) == Plan.limit("free", :credits_month)
      assert Enum.any?(Billing.list_credit_entries(user), &(&1.reason == "refund"))
    end
  end

  describe "tiers" do
    test "an unpaid subscription falls back to free limits", %{user: user} do
      {:ok, _} =
        Billing.upsert_subscription(user, %{tier: "ultra", status: "canceled"})

      assert Billing.tier(user) == "free"
    end

    test "a past-due subscription keeps its entitlement", %{user: user} do
      {:ok, _} = Billing.upsert_subscription(user, %{tier: "pro", status: "past_due"})

      assert Billing.tier(user) == "pro"
    end
  end
end
