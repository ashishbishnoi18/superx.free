defmodule SuperXWeb.ContactExportControllerTest do
  use SuperXWeb.ConnCase, async: false

  import SuperX.Fixtures

  alias SuperX.{Accounts, Signals}

  setup %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, token} = Accounts.create_session(user)
    conn = init_test_session(conn, %{user_token: token})

    %{conn: conn, account: account}
  end

  test "streams the selected list as an attachment", %{conn: conn, account: account} do
    {:ok, list} = Signals.create_contact_list(account, %{name: "Warm leads"})

    Signals.upsert_leads([
      %{x_account_id: account.id, handle: "included", display_name: "Included"},
      %{x_account_id: account.id, handle: "excluded", display_name: "Excluded"}
    ])

    included = Enum.find(Signals.list_leads(account), &(&1.handle == "included"))
    {:ok, :added} = Signals.toggle_contact_list_membership(account, included.id, list.id)

    conn = get(conn, ~p"/contacts/export?list=#{list.id}")
    csv = response(conn, 200)

    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="warm-leads-contacts.csv")]

    assert csv =~ "included"
    refute csv =~ "excluded"
  end

  test "does not export a list owned by another account", %{conn: conn} do
    %{account: other_account} = user_fixture()
    {:ok, other_list} = Signals.create_contact_list(other_account, %{name: "Other"})

    assert get(conn, ~p"/contacts/export?list=#{other_list.id}") |> response(404) == "Not found"
  end
end
