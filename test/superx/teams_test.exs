defmodule SuperX.TeamsTest do
  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.{Billing, Teams}
  alias SuperX.Teams.Invitation

  describe "membership entitlement" do
    test "a member inherits the owner's fresh tier in their own quota rows" do
      %{user: owner} = user_fixture()
      %{user: member} = user_fixture()

      {:ok, _subscription} =
        Billing.upsert_subscription(owner, %{tier: "advanced", status: "active"})

      invitation = invite(owner, "member@example.com")
      assert {:ok, linked_member} = Teams.accept_invitation(member, invitation.token)

      assert Billing.tier(member) == "advanced"
      assert linked_member.team_owner_id == owner.id

      quota = Billing.get_quota(member, "credits_month")
      assert quota.user_id == member.id
      assert quota.limit == Billing.Plan.limit("advanced", :credits_month)
    end

    test "removing a member drops them to the default tier immediately" do
      %{user: owner} = user_fixture()
      %{user: member} = user_fixture()

      {:ok, _subscription} =
        Billing.upsert_subscription(owner, %{tier: "ultra", status: "active"})

      invitation = invite(owner, "removed@example.com")
      assert {:ok, _member} = Teams.accept_invitation(member, invitation.token)
      assert Billing.tier(member) == "ultra"

      assert {:ok, removed} = Teams.remove_member(owner, member.id)
      assert is_nil(removed.team_owner_id)
      assert Billing.tier(member) == Billing.default_tier()
    end

    test "a lapsed owner subscription drops every member" do
      %{user: owner} = user_fixture()
      %{user: member} = user_fixture()

      {:ok, _subscription} = Billing.upsert_subscription(owner, %{tier: "pro", status: "active"})
      invitation = invite(owner, "lapsed@example.com")
      assert {:ok, _member} = Teams.accept_invitation(member, invitation.token)
      assert Billing.tier(member) == "pro"

      {:ok, _subscription} = Billing.upsert_subscription(owner, %{status: "canceled"})
      assert Billing.tier(member) == Billing.default_tier()
    end

    test "a past-due owner only keeps members through the paid period" do
      %{user: owner} = user_fixture()
      %{user: member} = user_fixture()
      period_end = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      {:ok, _subscription} =
        Billing.upsert_subscription(owner, %{
          tier: "pro",
          status: "past_due",
          current_period_end: period_end
        })

      invitation = invite(owner, "past-due@example.com")
      assert {:ok, _member} = Teams.accept_invitation(member, invitation.token)
      assert Billing.tier(member) == Billing.default_tier()
    end
  end

  describe "invitations" do
    test "a member cannot invite another account" do
      %{user: owner} = user_fixture()
      %{user: member} = user_fixture()

      invitation = invite(owner, "first@example.com")
      assert {:ok, _member} = Teams.accept_invitation(member, invitation.token)

      assert {:error, :member_cannot_invite} =
               Teams.invite(member, %{"email" => "second@example.com"})
    end

    test "an invitation cannot be accepted twice" do
      %{user: owner} = user_fixture()
      %{user: first} = user_fixture()
      %{user: second} = user_fixture()

      invitation = invite(owner, "once@example.com")

      assert {:ok, _member} = Teams.accept_invitation(first, invitation.token)
      assert {:error, :already_accepted} = Teams.accept_invitation(second, invitation.token)
      assert Billing.seat_count(owner) == 1
    end

    test "concurrent acceptance grants exactly one seat" do
      %{user: owner} = user_fixture()
      %{user: first} = user_fixture()
      %{user: second} = user_fixture()
      invitation = invite(owner, "race@example.com")
      parent = self()

      results =
        [first, second]
        |> Enum.map(fn invitee ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(SuperX.Repo, parent, self())
            Teams.accept_invitation(invitee, invitation.token)
          end)
        end)
        |> Task.await_many(15_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :already_accepted}, &1)) == 1
      assert Billing.seat_count(owner) == 1
    end

    test "an expired invitation is refused and marked expired" do
      %{user: owner} = user_fixture()
      %{user: invitee} = user_fixture()

      expired_at = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      {:ok, invitation, _url} =
        Teams.invite(owner, %{"email" => "late@example.com", "expires_at" => expired_at})

      assert {:error, :expired} = Teams.accept_invitation(invitee, invitation.token)
      assert Repo.get!(Invitation, invitation.id).status == "expired"
      refute Teams.member?(invitee)
    end

    test "self-membership and ownership chains are refused" do
      %{user: owner} = user_fixture()
      %{user: other_owner} = user_fixture()
      %{user: member} = user_fixture()

      self_invitation = invite(owner, "owner@example.com")
      assert {:error, :self_membership} = Teams.accept_invitation(owner, self_invitation.token)

      member_invitation = invite(owner, "member@example.com")
      assert {:ok, _member} = Teams.accept_invitation(member, member_invitation.token)

      chain_invitation = invite(other_owner, "owner-as-member@example.com")

      assert {:error, :invitee_owns_team} =
               Teams.accept_invitation(owner, chain_invitation.token)
    end
  end

  describe "seat counting and pricing" do
    test "counts accepted members, not the owner or pending invitations" do
      %{user: owner} = user_fixture()
      %{user: first} = user_fixture()
      %{user: second} = user_fixture()

      first_invitation = invite(owner, "first-seat@example.com")
      second_invitation = invite(owner, "second-seat@example.com")
      _pending = invite(owner, "pending@example.com")

      assert {:ok, _member} = Teams.accept_invitation(first, first_invitation.token)
      assert {:ok, _member} = Teams.accept_invitation(second, second_invitation.token)
      assert Billing.seat_count(owner) == 2
    end

    test "applies every volume threshold" do
      assert Billing.seat_discount_percent(0) == 0
      assert Billing.seat_discount_percent(1) == 0
      assert Billing.seat_discount_percent(2) == 25
      assert Billing.seat_discount_percent(10) == 25
      assert Billing.seat_discount_percent(11) == 30
      assert Billing.seat_discount_percent(50) == 30
      assert Billing.seat_discount_percent(51) == 35

      assert Billing.seat_pricing("pro", :month, 2) == %{
               count: 2,
               discount_percent: 25,
               unit_cents: 2175,
               total_cents: 4350
             }

      assert Billing.seat_pricing("pro", :month, 11).unit_cents == 2030
      assert Billing.seat_pricing("pro", :month, 51).unit_cents == 1885
    end
  end

  defp invite(owner, email) do
    {:ok, invitation, url} = Teams.invite(owner, %{"email" => email})
    assert String.ends_with?(url, invitation.token)
    invitation
  end
end
