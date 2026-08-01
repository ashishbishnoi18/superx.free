defmodule SuperX.ContactListsTest do
  use SuperX.DataCase, async: true

  import SuperX.Fixtures

  alias SuperX.Repo
  alias SuperX.Signals
  alias SuperX.Signals.ContactExport

  setup do
    user_fixture()
  end

  defp lead(account, handle, overrides \\ %{}) do
    Map.merge(
      %{
        x_account_id: account.id,
        handle: handle,
        display_name: String.capitalize(handle),
        bio: "A public profile",
        followers_count: 1_000,
        score: 70,
        reason: "Strong fit",
        notes: "Private outreach note"
      },
      overrides
    )
  end

  test "agents file new and already-known contacts into their chosen list", %{account: account} do
    {:ok, partners} = Signals.create_contact_list(account, %{name: "Partners"})

    {:ok, agent} =
      Signals.create_agent(account, %{
        kind: "keyword",
        target: "postgres",
        contact_list_id: partners.id
      })

    assert {1, _} = Signals.upsert_leads([lead(account, "known")])
    assert Signals.list_leads(account, list: partners) == []

    assert {1, _} =
             Signals.upsert_leads([
               lead(account, "known", %{signal_agent_id: agent.id, score: 90})
             ])

    assert [%{handle: "known", score: 90}] = Signals.list_leads(account, list: partners)
  end

  test "deleting an agent destination returns it to Followers", %{account: account} do
    {:ok, temporary} = Signals.create_contact_list(account, %{name: "Temporary"})

    {:ok, agent} =
      Signals.create_agent(account, %{
        kind: "keyword",
        target: "postgres",
        contact_list_id: temporary.id
      })

    assert {:ok, _list} = Signals.delete_contact_list(account, temporary.id)
    reloaded = Signals.get_agent(account, agent.id)
    followers = Enum.find(Signals.list_contact_lists(account), &(&1.kind == "followers"))

    assert reloaded.contact_list_id == followers.id

    Signals.upsert_leads([lead(account, "later", %{signal_agent_id: agent.id})])
    assert [%{handle: "later"}] = Signals.list_leads(account, list: followers)
  end

  test "manual membership is account-scoped and Engage follows workflow state", %{
    account: account
  } do
    %{account: other_account} = user_fixture()
    {:ok, shortlist} = Signals.create_contact_list(account, %{name: "Shortlist"})
    {:ok, other_list} = Signals.create_contact_list(other_account, %{name: "Other"})

    Signals.upsert_leads([
      lead(account, "active"),
      lead(account, "waiting"),
      lead(other_account, "outsider")
    ])

    active = Enum.find(Signals.list_leads(account), &(&1.handle == "active"))
    waiting = Enum.find(Signals.list_leads(account), &(&1.handle == "waiting"))

    assert {:ok, :added} =
             Signals.toggle_contact_list_membership(account, waiting.id, shortlist.id)

    assert [%{handle: "waiting"}] = Signals.list_leads(account, list: shortlist)

    assert {:error, :not_found} =
             Signals.toggle_contact_list_membership(account, waiting.id, other_list.id)

    engage = Enum.find(Signals.list_contact_lists(account), &(&1.kind == "engage"))
    assert Signals.list_leads(account, list: engage) == []

    {:ok, active} = Signals.set_lead_status(active, "contacted")
    assert Enum.map(Signals.list_leads(account, list: engage), & &1.handle) == [active.handle]

    {:ok, _active} = Signals.set_lead_status(active, "archived")
    assert Signals.list_leads(account, list: engage) == []
  end

  test "a public capability omits private research, rotates and revokes", %{account: account} do
    {:ok, list} = Signals.create_contact_list(account, %{name: "Founders"})
    Signals.upsert_leads([lead(account, "alice", %{location: "Private context"})])
    [alice] = Signals.list_leads(account)
    {:ok, :added} = Signals.toggle_contact_list_membership(account, alice.id, list.id)

    {:ok, first} = Signals.create_contact_list_share(account, list)
    public = Signals.public_contact_list_share(first.token)

    assert public.list.name == "Founders"
    assert [%{handle: "alice", bio: "A public profile"} = contact] = public.contacts

    assert Map.keys(contact) |> Enum.sort() ==
             [:bio, :display_name, :followers_count, :handle, :verified]

    refute inspect(public) =~ "Private outreach note"
    refute inspect(public) =~ "Strong fit"
    refute inspect(public) =~ "Private context"

    {:ok, second} = Signals.create_contact_list_share(account, list)
    assert second.token != first.token
    assert Signals.public_contact_list_share(first.token) == nil

    assert :ok = Signals.revoke_contact_list_share(account, list)
    assert Signals.public_contact_list_share(second.token) == nil
  end

  test "the export stream stays inside the selected list and neutralises formulas", %{
    account: account
  } do
    {:ok, list} = Signals.create_contact_list(account, %{name: "Outreach"})

    Signals.upsert_leads([
      lead(account, "included", %{bio: "=HYPERLINK(\"bad\")"}),
      lead(account, "excluded")
    ])

    included = Enum.find(Signals.list_leads(account), &(&1.handle == "included"))
    {:ok, :added} = Signals.toggle_contact_list_membership(account, included.id, list.id)

    {:ok, contacts} =
      Repo.transaction(fn -> Signals.stream_contact_export(account, list) |> Enum.to_list() end)

    assert Enum.map(contacts, & &1.handle) == ["included"]

    csv = IO.iodata_to_binary([ContactExport.header(), ContactExport.rows(contacts)])
    assert csv =~ "\"display_name\",\"handle\",\"profile_url\""
    assert csv =~ "'=HYPERLINK(\"\"bad\"\")"
    refute csv =~ "excluded"
  end
end
