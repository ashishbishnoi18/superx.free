defmodule SuperXWeb.Layouts do
  @moduledoc """
  Application layouts and the persistent app shell.
  """

  use SuperXWeb, :html

  alias SuperX.Billing.Subscription

  embed_templates "layouts/*"

  @doc """
  The signed-in shell: fixed sidebar, scrolling content, composer drawer.
  """
  attr :flash, :map, required: true
  attr :current_user, :map, default: nil
  attr :current_x_account, :map, default: nil
  attr :quota, :map, default: nil
  attr :active, :atom, default: nil, doc: "which nav item to highlight"
  attr :inner_content, :any, default: nil, doc: "rendered by LiveView as the layout body"

  def app(assigns) do
    ~H"""
    <div class="flex h-full">
      <.sidebar
        current_user={@current_user}
        current_x_account={@current_x_account}
        quota={@quota}
        active={@active}
      />

      <main id="main-scroll" class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-5xl px-6 py-8 lg:px-10">
          {@inner_content}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :current_user, :map, default: nil
  attr :current_x_account, :map, default: nil
  attr :quota, :map, default: nil
  attr :active, :atom, default: nil

  defp sidebar(assigns) do
    ~H"""
    <aside class="hidden w-64 shrink-0 flex-col border-r md:flex" style="border-color: var(--border-subtle); background-color: var(--surface-raised)">
      <div class="flex items-center gap-2 px-4 py-4">
        <.logo class="size-7" />
        <span class="text-lg font-bold tracking-tight">SuperX</span>
      </div>

      <div :if={@current_x_account} class="space-y-2 px-3 pb-3">
        <button
          type="button"
          phx-click={JS.dispatch("superx:open-composer")}
          class="btn btn-primary w-full"
        >
          <.icon name="hero-pencil-square" class="size-4" /> Create a post
        </button>
      </div>

      <nav class="flex-1 space-y-6 overflow-y-auto px-3 pb-4">
        <div class="space-y-0.5">
          <.nav_link navigate={~p"/home"} icon="hero-home" active={@active == :home}>Home</.nav_link>
          <.nav_link navigate={~p"/queue"} icon="hero-calendar-days" active={@active == :queue}>
            Queue
          </.nav_link>
          <.nav_link navigate={~p"/analytics"} icon="hero-chart-bar" active={@active == :analytics}>
            Analytics
          </.nav_link>
        </div>

        <div class="space-y-0.5">
          <p class="nav-section">Create</p>
          <.nav_link
            navigate={~p"/ready-to-post"}
            icon="hero-sparkles"
            active={@active == :ready_to_post}
          >
            Ready to Post
          </.nav_link>
          <.nav_link
            navigate={~p"/inspiration"}
            icon="hero-light-bulb"
            active={@active == :inspiration}
          >
            Inspiration
          </.nav_link>
        </div>

        <div class="space-y-0.5">
          <p class="nav-section">Settings</p>
          <.nav_link navigate={~p"/voice"} icon="hero-microphone" active={@active == :voice}>
            Voice
          </.nav_link>
          <.nav_link navigate={~p"/accounts"} icon="hero-at-symbol" active={@active == :accounts}>
            Accounts
          </.nav_link>
          <.nav_link navigate={~p"/upgrade"} icon="hero-bolt" active={@active == :upgrade}>
            Upgrade
          </.nav_link>
        </div>
      </nav>

      <.credit_meter :if={@quota} quota={@quota} />
      <.account_footer current_user={@current_user} current_x_account={@current_x_account} />
    </aside>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class="nav-item" aria-current={@active && "page"}>
      <.icon name={@icon} class="size-[18px] shrink-0 opacity-70" />
      <span>{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  attr :quota, :map, required: true

  defp credit_meter(assigns) do
    credits = assigns.quota["credits_month"] || %{used: 0, limit: 0, remaining: 0}

    assigns =
      assign(assigns,
        credits: credits,
        pct:
          if(credits.limit > 0,
            do: min(round(credits.used / credits.limit * 100), 100),
            else: 0
          )
      )

    ~H"""
    <div class="px-3 py-3">
      <.link navigate={~p"/upgrade"} class="block rounded-xl px-3 py-2.5 hover:bg-[var(--surface-hover)]">
        <div class="flex items-baseline justify-between text-xs">
          <span class="font-semibold" style="color: var(--text-secondary)">AI credits</span>
          <span class="font-mono tabular-nums" style="color: var(--text-muted)">
            {@credits.remaining} left
          </span>
        </div>
        <div class="mt-1.5 h-1 overflow-hidden rounded-full" style="background-color: var(--surface-sunken)">
          <div class="h-full rounded-full bg-ember-500 transition-[width]" style={"width: #{@pct}%"} />
        </div>
      </.link>
    </div>
    """
  end

  attr :current_user, :map, default: nil
  attr :current_x_account, :map, default: nil

  defp account_footer(assigns) do
    ~H"""
    <div :if={@current_user} class="border-t p-3" style="border-color: var(--border-subtle)">
      <div class="flex items-center gap-2.5">
        <.avatar src={@current_x_account && @current_x_account.avatar_url} size="size-9" />
        <div class="min-w-0 flex-1">
          <p class="truncate text-sm font-semibold">
            {(@current_x_account && @current_x_account.display_name) || @current_user.name}
          </p>
          <p class="truncate text-xs" style="color: var(--text-muted)">
            <span :if={@current_x_account}>@{@current_x_account.handle}</span>
            <span :if={!@current_x_account}>No account connected</span>
          </p>
        </div>
        <.link
          href={~p"/sign-out"}
          method="delete"
          class="btn btn-ghost btn-sm px-2"
          title="Sign out"
        >
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
        </.link>
      </div>
      <p :if={@current_user.subscription} class="mt-2 px-1">
        <span class="badge badge-ember">{Subscription.label(@current_user.subscription)}</span>
      </p>
    </div>
    """
  end

  @doc "The SuperX flame mark."
  attr :class, :string, default: "size-6"

  def logo(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 32 32" fill="none" aria-hidden="true">
      <path
        d="M16 2c1.6 5.2-1.4 7.6-3.8 9.8C9.4 14.3 7 16.7 7 20.5 7 25.7 11 30 16 30s9-4.3 9-9.5c0-4.6-2.6-7.2-5-9.6-.9 1.6-2 2.6-3.3 3.2.7-3.4.6-7.6-.7-12.1z"
        fill="url(#flame)"
      />
      <path
        d="M16 30c2.9 0 5.2-2.4 5.2-5.4 0-2.6-1.6-4.2-3-5.6-.5.9-1.2 1.5-2 1.9.4-2 .4-4.4-.4-7-1 3-2.6 4.4-3.8 5.7-1.1 1.3-2.2 2.7-2.2 5 0 3 2.3 5.4 5.2 5.4z"
        fill="url(#core)"
      />
      <defs>
        <linearGradient id="flame" x1="16" y1="2" x2="16" y2="30" gradientUnits="userSpaceOnUse">
          <stop stop-color="#F97316" />
          <stop offset="1" stop-color="#DC2626" />
        </linearGradient>
        <linearGradient id="core" x1="16" y1="13" x2="16" y2="30" gradientUnits="userSpaceOnUse">
          <stop stop-color="#FDE047" />
          <stop offset="1" stop-color="#F97316" />
        </linearGradient>
      </defs>
    </svg>
    """
  end

  @doc "A round avatar with a neutral fallback."
  attr :src, :string, default: nil
  attr :size, :string, default: "size-9"
  attr :class, :string, default: ""

  def avatar(assigns) do
    ~H"""
    <img
      :if={@src}
      src={@src}
      alt=""
      loading="lazy"
      class={["shrink-0 rounded-full object-cover", @size, @class]}
      style="background-color: var(--surface-sunken)"
    />
    <div
      :if={!@src}
      class={["shrink-0 rounded-full", @size, @class]}
      style="background-color: var(--surface-sunken)"
    />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Light / dark / system switch.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      class="relative flex rounded-full border p-0.5"
      style="border-color: var(--border-strong); background-color: var(--surface-sunken)"
    >
      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop-micro", "System theme"},
            {"light", "hero-sun-micro", "Light theme"},
            {"dark", "hero-moon-micro", "Dark theme"}
          ]
        }
        type="button"
        class="rounded-full p-1.5 hover:bg-[var(--surface-raised)]"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        title={label}
        aria-label={label}
      >
        <.icon name={icon} class="size-4 opacity-70" />
      </button>
    </div>
    """
  end
end
