defmodule SuperXWeb.AccountsLive do
  @moduledoc """
  The user's account boundary: connected X identities, appearance, and
  credentials for scripts.

  These settings stay together because they belong to the person signed
  in, while posting schedules and voice remain properties of whichever X
  account they are currently acting as.
  """

  use SuperXWeb, :live_view

  alias SuperX.{Accounts, Billing, Teams}
  alias SuperX.Billing.Plan
  alias SuperXWeb.ApiRateLimit

  @themes [
    {"light", "Light", "Always use the Ink & Paper palette."},
    {"dark", "Dark", "Always use the warm graphite palette."},
    {"system", "System", "Follow this device's appearance setting."}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Accounts")
     |> assign(:themes, @themes)
     |> assign(:new_api_token, nil)
     |> assign(:token_form, token_form())
     |> assign(:invitation_form, invitation_form(socket.assigns.current_user))
     |> load_accounts()}
  end

  @impl true
  def handle_event("switch", %{"id" => id}, socket) do
    case Accounts.set_default_x_account(socket.assigns.current_user, id) do
      {:ok, _user} ->
        # Reload from scratch so every LiveView picks up the new account.
        {:noreply, push_navigate(socket, to: ~p"/home")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "That account isn't available.")}
    end
  end

  def handle_event("disconnect", %{"id" => id}, socket) do
    case Accounts.disconnect_x_account(socket.assigns.current_user, id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account disconnected. Scheduled posts for it were cancelled.")
         |> load_accounts()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "We couldn't disconnect that account.")}
    end
  end

  def handle_event("set_theme", %{"theme" => theme}, socket) do
    case Accounts.update_theme(socket.assigns.current_user, theme) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> load_accounts()
         |> push_event("set-theme", %{theme: theme})}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That appearance setting isn't recognised.")}
    end
  end

  def handle_event("create_api_token", %{"api_token" => params}, socket) do
    case Accounts.create_api_token(socket.assigns.current_user, params) do
      {:ok, _api_token, plaintext} ->
        {:noreply,
         socket
         |> assign(:new_api_token, plaintext)
         |> assign(:token_form, token_form())
         |> put_flash(:info, "API token created. Copy it before leaving this page.")
         |> load_accounts()}

      {:error, changeset} ->
        {:noreply, assign(socket, :token_form, to_form(changeset))}
    end
  end

  def handle_event("hide_api_token", _params, socket) do
    {:noreply, assign(socket, :new_api_token, nil)}
  end

  def handle_event("revoke_api_token", %{"id" => id}, socket) do
    case Accounts.revoke_api_token(socket.assigns.current_user, id) do
      {:ok, _api_token} ->
        {:noreply, socket |> put_flash(:info, "API token revoked.") |> load_accounts()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That API token isn't available.")}
    end
  end

  def handle_event("invite_member", %{"invitation" => params}, socket) do
    case Teams.invite(socket.assigns.current_user, params) do
      {:ok, _invitation, _url} ->
        {:noreply,
         socket
         |> assign(:invitation_form, invitation_form(socket.assigns.current_user))
         |> put_flash(:info, "Invitation created. Its link is ready to copy below.")
         |> load_accounts()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :invitation_form, to_form(changeset))}

      {:error, :member_cannot_invite} ->
        {:noreply, put_flash(socket, :error, "A team member cannot invite another member.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "We couldn't create that invitation.")}
    end
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket) do
    case Teams.revoke_invitation(socket.assigns.current_user, id) do
      {:ok, _invitation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation revoked.")
         |> load_accounts()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That invitation isn't available.")}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    case Teams.remove_member(socket.assigns.current_user, id) do
      {:ok, _member} ->
        {:noreply,
         socket
         |> put_flash(:info, "Member removed. Their account and data are unchanged.")
         |> load_accounts()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That member isn't available.")}
    end
  end

  defp load_accounts(socket) do
    user = Accounts.get_user_with_context!(socket.assigns.current_user.id)
    accounts = Accounts.list_x_accounts(user)
    tier = Billing.tier(user)
    api_usage = ApiRateLimit.usage(user)

    socket
    |> assign(:current_user, user)
    |> assign(:accounts, accounts)
    |> assign(:current_x_account, Accounts.current_x_account(user))
    |> assign(:account_limit, Plan.limit(tier, :x_accounts))
    |> assign(:tier, tier)
    |> assign(:api_limit, Plan.limit(tier, :api_requests_minute))
    |> assign(:api_usage, api_usage)
    |> assign(:theme, Accounts.theme(user))
    |> load_team(user)
    |> stream(:api_tokens, Accounts.list_api_tokens(user),
      reset: true,
      dom_id: &"api-token-#{&1.id}"
    )
  end

  defp load_team(socket, user) do
    team_owner = Teams.owner_for(user)
    members = if team_owner, do: [], else: Teams.list_members(user)
    invitations = if team_owner, do: [], else: Teams.list_invitations(user)

    socket
    |> assign(:team_owner, team_owner)
    |> stream(:team_members, members,
      reset: true,
      dom_id: &"team-member-#{&1.id}"
    )
    |> stream(:team_invitations, invitations,
      reset: true,
      dom_id: &"team-invitation-#{&1.id}"
    )
  end

  defp token_form, do: to_form(%{"name" => ""}, as: :api_token)
  defp invitation_form(user), do: user |> Teams.change_invitation() |> to_form()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header
      title="Accounts"
      description={"#{length(@accounts)} of #{@account_limit} connected on the #{String.capitalize(@tier)} plan."}
    >
      <:action>
        <.link
          :if={length(@accounts) < @account_limit}
          href={~p"/auth/x?redirect_to=/accounts"}
          class="act-key whitespace-nowrap"
        >
          Connect another
        </.link>
        <.link
          :if={length(@accounts) >= @account_limit}
          navigate={~p"/upgrade"}
          class="act whitespace-nowrap"
        >
          Upgrade for more
        </.link>
      </:action>
    </Layouts.page_header>

    <div class="flex flex-col">
      <div
        :for={account <- @accounts}
        class="flex items-center gap-4 border-t border-border py-4 last:border-b"
      >
        <Layouts.avatar
          src={account.avatar_url}
          name={account.display_name || account.handle}
          size="size-8"
        />

        <div class="min-w-0 flex-1">
          <%!-- Two different facts, so two badges. "active" alone was doing
                both jobs and read as connection health, which produced an
                account badged active directly above "X rejected the stored
                credentials". --%>
          <p class="flex flex-wrap items-center gap-2">
            <span class="truncate">
              <span class="font-medium">{account.display_name || account.handle}</span>
              <span class="ml-1.5 text-faint">@{account.handle}</span>
            </span>
            <span
              :if={@current_x_account && account.id == @current_x_account.id}
              class="badge badge-ember"
            >
              selected
            </span>
            <span class={[
              "badge",
              if(account.reauth_needed, do: "badge-danger", else: "badge-success")
            ]}>
              {if account.reauth_needed, do: "needs reconnect", else: "connected"}
            </span>
          </p>
          <p class="nb-mono mt-0.5 text-[11px] text-faint">
            {format_count(account.followers_count)} followers
          </p>
          <p :if={account.reauth_needed} class="mt-1 text-[12px] text-destructive">
            {account.reauth_reason || "X rejected the stored credentials."}
          </p>
        </div>

        <div class="flex shrink-0 items-center gap-5 text-xs">
          <.link :if={account.reauth_needed} href={~p"/auth/x?redirect_to=/accounts"} class="act-key">
            Reconnect
          </.link>
          <button
            :if={!@current_x_account || account.id != @current_x_account.id}
            phx-click="switch"
            phx-value-id={account.id}
            class="act-key"
          >
            Switch to
          </button>
          <button
            phx-click="disconnect"
            phx-value-id={account.id}
            data-confirm={"Disconnect @#{account.handle}? Scheduled posts for it will be cancelled."}
            class="act-danger"
          >
            Disconnect
          </button>
        </div>
      </div>
    </div>

    <section id="team-settings" class="mt-9 border-t border-border py-6">
      <div class="grid grid-cols-1 gap-7 sm:grid-cols-[14rem_minmax(0,1fr)]">
        <div>
          <h2 class="text-[15px] font-semibold">Team</h2>
          <p class="mt-1 text-[12px] leading-[1.6] text-faint">
            Each member keeps their own account and data. Only plan entitlement comes from the owner.
          </p>
        </div>

        <div :if={@team_owner} id="team-membership">
          <p class="nb-eyebrow">Your seat</p>
          <div class="mt-3 flex items-center gap-3 border-y border-border py-4">
            <Layouts.avatar src={@team_owner.avatar_url} size="size-8" />
            <div class="min-w-0">
              <p class="truncate font-medium">
                {@team_owner.name || @team_owner.email || "Team owner"}
              </p>
              <p :if={@team_owner.email} class="mt-0.5 truncate text-[12px] text-faint">
                {@team_owner.email}
              </p>
            </div>
          </div>
          <p class="mt-3 max-w-[58ch] text-[12px] leading-[1.6] text-muted-foreground">
            Your X accounts, posts, drafts, quotas, and voice profiles remain yours. The owner only
            supplies your {String.capitalize(@tier)} plan entitlement.
          </p>
        </div>

        <div :if={!@team_owner}>
          <div id="team-member-list" phx-update="stream" class="flex flex-col">
            <div id="team-members-empty" class="border-y border-border py-5 only:block">
              <p class="text-muted-foreground">No members yet.</p>
              <p class="mt-1 text-[12px] text-faint">
                Invite someone when they need their own SuperX account on your plan.
              </p>
            </div>
            <div
              :for={{id, member} <- @streams.team_members}
              id={id}
              class="flex items-center gap-3 border-b border-border py-4 first:border-t"
            >
              <Layouts.avatar src={member.avatar_url} size="size-8" />
              <div class="min-w-0 flex-1">
                <p class="truncate font-medium">{member.name || member.email || "Team member"}</p>
                <p :if={member.email} class="mt-0.5 truncate text-[12px] text-faint">
                  {member.email}
                </p>
              </div>
              <button
                type="button"
                phx-click="remove_member"
                phx-value-id={member.id}
                data-confirm={"Remove #{member.name || member.email || "this member"}? They will return to the default plan immediately."}
                class="act-danger shrink-0 text-xs"
              >
                Remove
              </button>
            </div>
          </div>

          <.form
            for={@invitation_form}
            id="team-invitation-form"
            phx-submit="invite_member"
            class="mt-7 flex max-w-[34rem] items-end gap-5"
          >
            <div class="min-w-0 flex-1">
              <.input
                field={@invitation_form[:email]}
                type="email"
                label="Invite by email"
                placeholder="member@example.com"
                autocomplete="email"
                required
              />
            </div>
            <button type="submit" class="btn-primary mb-4 shrink-0">Create invitation</button>
          </.form>

          <div class="mt-7">
            <p class="nb-eyebrow mb-2">Invitations</p>
            <div id="team-invitation-list" phx-update="stream" class="flex flex-col">
              <p
                id="team-invitations-empty"
                class="border-y border-border py-4 text-muted-foreground only:block"
              >
                No pending invitations. New links will remain here until they are used or revoked.
              </p>
              <div
                :for={{id, invitation} <- @streams.team_invitations}
                id={id}
                class="border-b border-border py-4 first:border-t"
              >
                <div class="flex items-baseline justify-between gap-5">
                  <p class="min-w-0 truncate font-medium">{invitation.email}</p>
                  <span class="nb-mono shrink-0 text-[11px] text-faint">
                    {invitation.status}
                  </span>
                </div>
                <div :if={invitation.status == "pending"} class="mt-2 flex items-end gap-5">
                  <div class="min-w-0 flex-1">
                    <.input
                      id={"invitation-link-#{invitation.id}"}
                      name={"invitation-link-#{invitation.id}"}
                      type="url"
                      value={Teams.invitation_url(invitation)}
                      readonly
                      class="nb-mono w-full input text-[11px]"
                    />
                  </div>
                  <button
                    type="button"
                    phx-click="revoke_invitation"
                    phx-value-id={invitation.id}
                    data-confirm={"Revoke the invitation for #{invitation.email}?"}
                    class="act-danger mb-4 shrink-0 text-xs"
                  >
                    Revoke
                  </button>
                </div>
                <p :if={invitation.status == "expired"} class="mt-1 text-[12px] text-faint">
                  This link expired. Create a new invitation if they still need a seat.
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>

    <section id="appearance-settings" class="mt-9 border-t border-border py-6">
      <div class="grid grid-cols-1 gap-7 sm:grid-cols-[14rem_minmax(0,1fr)]">
        <div>
          <h2 class="text-[15px] font-semibold">Appearance</h2>
          <p class="mt-1 text-[12px] leading-[1.6] text-faint">
            Used on every device where you sign in.
          </p>
        </div>

        <div>
          <div id="theme-options" class="flex gap-6 border-b border-border">
            <button
              :for={{value, label, _description} <- @themes}
              id={"theme-#{value}"}
              type="button"
              phx-click="set_theme"
              phx-value-theme={value}
              class="tab"
              aria-pressed={to_string(@theme == value)}
              aria-selected={to_string(@theme == value)}
            >
              {label}
            </button>
          </div>
          <p class="mt-3 text-[12px] text-muted-foreground">{theme_description(@themes, @theme)}</p>
        </div>
      </div>
    </section>

    <section id="api-access" class="mt-9 border-t border-border py-6">
      <div class="grid grid-cols-1 gap-7 sm:grid-cols-[14rem_minmax(0,1fr)]">
        <div>
          <h2 class="text-[15px] font-semibold">API access</h2>
          <p class="mt-1 text-[12px] leading-[1.6] text-faint">
            Read the selected account and put approved drafts into its queue, from a
            script or an MCP client.
          </p>
        </div>

        <div>
          <div
            id="api-usage"
            data-limit={@api_limit}
            data-requests-today={@api_usage.requests_today}
            class="mb-9 flex flex-wrap items-center justify-between gap-3 border-y border-border py-3"
          >
            <p class="text-[12px] text-muted-foreground">
              <span class="font-medium text-foreground">{Plan.get(@tier).name}</span>
              <span class="mx-1.5 text-faint">·</span>
              <span class="nb-mono">{@api_limit} req/min</span>
              <span class="mx-1.5 text-faint">·</span>
              Requests today (UTC):
              <span class="nb-mono text-foreground">{@api_usage.requests_today}</span>
            </p>
            <.link navigate={~p"/api"} class="act text-xs">API docs</.link>
          </div>

          <div
            :if={@new_api_token}
            id="new-api-token"
            class="mb-9 border-y border-border py-4"
          >
            <div class="flex items-baseline justify-between gap-6">
              <span class="nb-eyebrow">Shown once</span>
              <button type="button" phx-click="hide_api_token" class="act text-xs">Hide</button>
            </div>
            <code class="nb-mono mt-3 block break-all text-[12px] text-foreground">
              {@new_api_token}
            </code>
            <p class="mt-2 text-[12px] text-muted-foreground">
              Copy this token now. SuperX stores its hash and cannot show it again.
            </p>
          </div>

          <.form
            for={@token_form}
            id="api-token-form"
            phx-submit="create_api_token"
            class="flex max-w-[34rem] items-end gap-5"
          >
            <div class="min-w-0 flex-1">
              <.input
                field={@token_form[:name]}
                type="text"
                label="Token name"
                placeholder="Reporting script"
                autocomplete="off"
                required
              />
            </div>
            <button type="submit" class="act-key mb-4 shrink-0 text-xs">Create token</button>
          </.form>

          <div id="api-token-list" phx-update="stream" class="mt-6 flex flex-col">
            <p id="api-tokens-empty" class="hidden py-4 text-muted-foreground only:block">
              No API tokens yet. Create one when a script or MCP client needs this account.
            </p>
            <div
              :for={{id, api_token} <- @streams.api_tokens}
              id={id}
              class="grid grid-cols-1 gap-3 border-b border-border py-3 first:border-t sm:grid-cols-[minmax(0,1fr)_auto]"
            >
              <div class="min-w-0">
                <p class="font-medium">{api_token.name}</p>
                <p class="nb-mono mt-1 text-[11px] text-faint">
                  {api_token.token_prefix}.… · created {format_token_time(
                    api_token.inserted_at,
                    @current_user.timezone
                  )}
                </p>
              </div>

              <div class="flex items-center gap-5 text-xs">
                <span :if={api_token.revoked_at} class="nb-mono text-[11px] text-faint">
                  revoked
                </span>
                <button
                  :if={is_nil(api_token.revoked_at)}
                  type="button"
                  phx-click="revoke_api_token"
                  phx-value-id={api_token.id}
                  data-confirm={"Revoke #{api_token.name}? Scripts using it will stop working."}
                  class="act-danger"
                >
                  Revoke
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp theme_description(themes, selected) do
    case Enum.find(themes, fn {value, _label, _description} -> value == selected end) do
      {_value, _label, description} -> description
      nil -> ""
    end
  end

  defp format_token_time(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone, Tz.TimeZoneDatabase) do
      {:ok, local} -> Calendar.strftime(local, "%-d %b %Y")
      _ -> Calendar.strftime(datetime, "%-d %b %Y")
    end
  end

  defp format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n), do: to_string(n)
end
