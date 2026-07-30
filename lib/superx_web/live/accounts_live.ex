defmodule SuperXWeb.AccountsLive do
  @moduledoc """
  Manage connected X accounts: switch which one you're acting as, connect
  another, reconnect one whose tokens expired, or disconnect.
  """

  use SuperXWeb, :live_view

  alias SuperX.{Accounts, Billing}
  alias SuperX.Billing.Plan

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Accounts") |> load_accounts()}
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
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h1 class="text-2xl font-bold tracking-tight">Accounts</h1>
          <p class="mt-1 text-sm" style="color: var(--text-secondary)">
            {length(@accounts)} of {@account_limit} connected on the {String.capitalize(@tier)} plan.
          </p>
        </div>

        <.link
          :if={length(@accounts) < @account_limit}
          href={~p"/auth/x?redirect_to=/accounts"}
          class="btn btn-primary"
        >
          <.icon name="hero-plus" class="size-4" /> Connect account
        </.link>
        <.link :if={length(@accounts) >= @account_limit} navigate={~p"/upgrade"} class="btn btn-secondary">
          Upgrade for more
        </.link>
      </div>

      <div class="space-y-3">
        <div
          :for={account <- @accounts}
          class="card flex items-center gap-4 p-4"
        >
          <Layouts.avatar src={account.avatar_url} size="size-11" />

          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <p class="truncate font-semibold">{account.display_name || account.handle}</p>
              <span :if={@current_x_account && account.id == @current_x_account.id} class="badge badge-ember">
                Active
              </span>
              <span :if={account.reauth_needed} class="badge" style="color: var(--color-ember-700)">
                Needs reconnect
              </span>
            </div>
            <p class="truncate text-sm" style="color: var(--text-muted)">
              @{account.handle} · {format_count(account.followers_count)} followers
            </p>
            <p :if={account.reauth_needed} class="mt-1 text-xs" style="color: var(--text-secondary)">
              {account.reauth_reason || "X rejected the stored credentials."}
            </p>
          </div>

          <div class="flex shrink-0 items-center gap-2">
            <.link :if={account.reauth_needed} href={~p"/auth/x?redirect_to=/accounts"} class="btn btn-soft btn-sm">
              Reconnect
            </.link>
            <button
              :if={!@current_x_account || account.id != @current_x_account.id}
              phx-click="switch"
              phx-value-id={account.id}
              class="btn btn-secondary btn-sm"
            >
              Switch to
            </button>
            <button
              phx-click="disconnect"
              phx-value-id={account.id}
              data-confirm={"Disconnect @#{account.handle}? Scheduled posts for it will be cancelled."}
              class="btn btn-ghost btn-sm"
              title="Disconnect"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_count(n), do: to_string(n)
end
