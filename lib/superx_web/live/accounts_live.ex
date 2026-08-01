defmodule SuperXWeb.AccountsLive do
  @moduledoc """
  The user's account boundary: connected X identities, appearance, and
  credentials for scripts.

  These settings stay together because they belong to the person signed
  in, while posting schedules and voice remain properties of whichever X
  account they are currently acting as.
  """

  use SuperXWeb, :live_view

  alias SuperX.{Accounts, Billing}
  alias SuperX.Billing.Plan

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

  defp load_accounts(socket) do
    user = Accounts.get_user_with_context!(socket.assigns.current_user.id)
    accounts = Accounts.list_x_accounts(user)
    tier = Billing.tier(user)

    socket
    |> assign(:current_user, user)
    |> assign(:accounts, accounts)
    |> assign(:current_x_account, Accounts.current_x_account(user))
    |> assign(:account_limit, Plan.limit(tier, :x_accounts))
    |> assign(:tier, tier)
    |> assign(:theme, Accounts.theme(user))
    |> stream(:api_tokens, Accounts.list_api_tokens(user),
      reset: true,
      dom_id: &"api-token-#{&1.id}"
    )
  end

  defp token_form, do: to_form(%{"name" => ""}, as: :api_token)

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
        <Layouts.avatar src={account.avatar_url} size="size-8" />

        <div class="min-w-0 flex-1">
          <p class="truncate">
            <span class="font-medium">{account.display_name || account.handle}</span>
            <span class="ml-1.5 text-faint">@{account.handle}</span>
            <span
              :if={@current_x_account && account.id == @current_x_account.id}
              class="nb-mono ml-2 text-[11px] text-primary"
            >
              active
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

    <section id="appearance-settings" class="mt-12 border-t border-border py-6">
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
              aria-pressed={@theme == value}
              aria-selected={@theme == value}
            >
              {label}
            </button>
          </div>
          <p class="mt-3 text-[12px] text-muted-foreground">{theme_description(@themes, @theme)}</p>
        </div>
      </div>
    </section>

    <section id="api-access" class="mt-6 border-t border-border py-6">
      <div class="grid grid-cols-1 gap-7 sm:grid-cols-[14rem_minmax(0,1fr)]">
        <div>
          <h2 class="text-[15px] font-semibold">API access</h2>
          <p class="mt-1 text-[12px] leading-[1.6] text-faint">
            Read the selected account's queue, shelf, and analytics from a script.
          </p>
        </div>

        <div>
          <div
            :if={@new_api_token}
            id="new-api-token"
            class="mb-6 border-y border-border py-4"
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
              No API tokens yet. Create one when a script needs to read this account.
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
