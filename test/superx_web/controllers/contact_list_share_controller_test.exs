defmodule SuperXWeb.ContactListShareControllerTest do
  use SuperXWeb.ConnCase, async: true

  import SuperX.Fixtures

  alias SuperX.Signals

  test "serves public profile facts without private CRM fields and stops after revocation", %{
    conn: conn
  } do
    %{account: account} = user_fixture(display_name: "Circle owner")
    {:ok, list} = Signals.create_contact_list(account, %{name: "Builders"})

    Signals.upsert_leads([
      %{
        x_account_id: account.id,
        handle: "builder",
        display_name: "Builder",
        bio: "Builds useful things",
        reason: "Private qualification",
        notes: "Private note",
        source_post_text: "Private source"
      }
    ])

    [contact] = Signals.list_leads(account)
    {:ok, :added} = Signals.toggle_contact_list_membership(account, contact.id, list.id)
    {:ok, share} = Signals.create_contact_list_share(account, list)

    conn = get(conn, ~p"/circle/#{share.token}")
    html = html_response(conn, 200)

    assert html =~ "shared-contact-list"
    assert html =~ "Builders"
    assert html =~ "Builds useful things"
    refute html =~ "Private qualification"
    refute html =~ "Private note"
    refute html =~ "Private source"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]

    :ok = Signals.revoke_contact_list_share(account, list)
    assert get(build_conn(), ~p"/circle/#{share.token}") |> response(404) == "Not found"
  end
end
