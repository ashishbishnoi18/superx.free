defmodule SuperXWeb.ContactsLiveTest do
  use SuperXWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SuperX.Fixtures

  alias SuperX.{Accounts, Signals}

  setup %{conn: conn} do
    %{user: user, account: account} = user_fixture()
    {:ok, token} = Accounts.create_session(user)
    conn = init_test_session(conn, %{user_token: token})

    Signals.upsert_leads([
      %{
        x_account_id: account.id,
        handle: "builder",
        display_name: "Builder",
        bio: "Builds useful things",
        score: 82
      }
    ])

    [lead] = Signals.list_leads(account)
    %{conn: conn, account: account, lead: lead}
  end

  test "creates a list, manages membership and shares the selected circle", %{
    conn: conn,
    account: account,
    lead: lead
  } do
    {:ok, view, _html} = live(conn, ~p"/contacts")

    view |> element("button[phx-click=show_new_list]") |> render_click()
    view |> form("#contact-list-form", list: %{name: "Partners"}) |> render_submit()

    list = Enum.find(Signals.list_contact_lists(account), &(&1.name == "Partners"))
    assert has_element?(view, "#contact-list-#{list.id}[aria-current=page]")
    assert has_element?(view, "#contacts-empty", "No contacts in Partners")

    view |> element("#contacts-empty a", "Browse all contacts") |> render_click()

    view
    |> element("#contact-lists-#{lead.id} button[phx-value-list-id=\"#{list.id}\"]")
    |> render_click()

    view |> element("#contact-list-#{list.id}") |> render_click()
    assert has_element?(view, "#leads-#{lead.id}")

    view |> element("button[phx-click=create_share]") |> render_click()
    assert has_element?(view, "#contact-list-share a[href^=\"http://\"]")

    view |> element("#contact-list-share button[phx-click=revoke_share]") |> render_click()
    refute has_element?(view, "#contact-list-share")
  end

  test "Engage updates from the contact workflow without manual membership", %{
    conn: conn,
    account: account,
    lead: lead
  } do
    engage = Enum.find(Signals.list_contact_lists(account), &(&1.kind == "engage"))
    {:ok, view, _html} = live(conn, ~p"/contacts")

    view
    |> element("#leads-#{lead.id} button[phx-value-status=contacted]")
    |> render_click()

    view |> element("#contact-list-#{engage.id}") |> render_click()

    assert has_element?(view, "#selected-list-note", "Updates automatically")
    assert has_element?(view, "#leads-#{lead.id}")
  end
end
