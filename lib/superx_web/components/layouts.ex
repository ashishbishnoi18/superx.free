defmodule SuperXWeb.Layouts do
  @moduledoc """
  Application layouts and the persistent app shell.

  The shell follows the editorial constitution: hairlines and air, no
  frames. The only colour in the chrome is the ember tick marking where
  you are.
  """

  use SuperXWeb, :html

  alias SuperX.Accounts
  alias SuperX.Billing.Subscription

  embed_templates "layouts/*"

  @site_url "https://superx.free/"
  @default_page_title "SuperX — Free, open-source X growth tool"
  @default_page_description "SuperX is a free, open-source, self-hosted alternative to superx.so for drafting, scheduling, publishing, and measuring posts on X (Twitter)."

  defp root_theme(nil), do: "system"
  defp root_theme(user), do: Accounts.theme(user)

  defp default_page_title, do: @default_page_title

  defp meta_title(assigns) do
    case assigns[:page_title] do
      title when is_binary(title) and title != "" -> "#{title} · SuperX"
      _title -> @default_page_title
    end
  end

  defp page_description(assigns) do
    case assigns[:page_description] do
      description when is_binary(description) and description != "" -> description
      _description -> @default_page_description
    end
  end

  defp canonical_url(assigns) do
    case assigns[:canonical_url] do
      url when is_binary(url) and url != "" -> url
      _url -> @site_url
    end
  end

  @doc """
  The signed-in shell: fixed sidebar, scrolling content.
  """
  attr :flash, :map, required: true
  attr :current_user, :map, default: nil
  attr :current_x_account, :map, default: nil
  attr :quota, :map, default: nil
  attr :active, :atom, default: nil, doc: "which nav item to highlight"
  attr :inner_content, :any, default: nil

  def app(assigns) do
    ~H"""
    <div class="flex h-full">
      <.sidebar
        current_user={@current_user}
        current_x_account={@current_x_account}
        quota={@quota}
        active={@active}
      />

      <div class="flex min-w-0 flex-1 flex-col">
        <%!-- Below `md` the sidebar is display:none. Without this bar the
              product has no navigation at all on a phone. --%>
        <div class="mobile-bar md:hidden">
          <button
            type="button"
            class="icon-act"
            aria-label="Open navigation"
            aria-controls="mobile-nav"
            aria-expanded="false"
            phx-click={open_mobile_nav()}
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>
          <.logo class="text-[15px]" />
        </div>

        <main id="main-scroll" class="flex-1 overflow-y-auto">
          <div class="measure page">
            {@inner_content}
          </div>
        </main>
      </div>
    </div>

    <.mobile_nav
      current_user={@current_user}
      current_x_account={@current_x_account}
      quota={@quota}
      active={@active}
    />

    <.flash_group flash={@flash} />
    """
  end

  defp open_mobile_nav(js \\ %JS{}) do
    js
    |> JS.remove_attribute("hidden", to: "#mobile-nav")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "[aria-controls='mobile-nav']")
    |> JS.focus_first(to: "#mobile-nav .mobile-drawer-panel")
  end

  defp close_mobile_nav(js \\ %JS{}) do
    js
    |> JS.set_attribute({"hidden", ""}, to: "#mobile-nav")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "[aria-controls='mobile-nav']")
  end

  attr :current_user, :map, default: nil
  attr :current_x_account, :map, default: nil
  attr :quota, :map, default: nil
  attr :active, :atom, default: nil

  defp mobile_nav(assigns) do
    ~H"""
    <div
      id="mobile-nav"
      class="mobile-drawer md:hidden"
      role="dialog"
      aria-modal="true"
      aria-label="Navigation"
      phx-window-keydown={close_mobile_nav()}
      phx-key="escape"
      hidden
    >
      <div class="mobile-drawer-scrim" phx-click={close_mobile_nav()} />

      <div class="mobile-drawer-panel">
        <div class="flex items-center justify-between px-[1.125rem] pb-3.5 pt-4">
          <.logo class="text-[15px]" />
          <button
            type="button"
            class="icon-act"
            aria-label="Close navigation"
            phx-click={close_mobile_nav()}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <%!-- Tapping a destination must dismiss the drawer: LiveView patches
              the page underneath without unmounting this element. --%>
        <nav
          class="flex flex-1 flex-col gap-5 overflow-y-auto px-3 py-1"
          phx-click={close_mobile_nav()}
        >
          <.nav_items active={@active} />
        </nav>

        <div class="flex flex-col gap-2.5 border-t border-border px-[1.125rem] pb-4 pt-3.5">
          <.credit_meter :if={@quota} quota={@quota} />
          <.account_footer
            current_user={@current_user}
            current_x_account={@current_x_account}
            quota={@quota}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :current_user, :map, default: nil
  attr :current_x_account, :map, default: nil
  attr :quota, :map, default: nil
  attr :active, :atom, default: nil

  defp sidebar(assigns) do
    ~H"""
    <aside class="hidden w-56 shrink-0 flex-col border-r border-border md:flex">
      <div class="px-[1.125rem] pb-3.5 pt-4">
        <.logo class="text-[15px]" />
      </div>

      <nav class="flex flex-1 flex-col gap-5 overflow-y-auto px-3 py-1">
        <.nav_items active={@active} />
      </nav>

      <div class="flex flex-col gap-2.5 border-t border-border px-[1.125rem] pb-4 pt-3.5">
        <.credit_meter :if={@quota} quota={@quota} />
        <.account_footer
          current_user={@current_user}
          current_x_account={@current_x_account}
          quota={@quota}
        />
      </div>
    </aside>
    """
  end

  # One definition of the navigation, rendered by both the desktop sidebar
  # and the mobile drawer. Two copies drift the moment a route is added.
  attr :active, :atom, default: nil

  defp nav_items(assigns) do
    ~H"""
    <.nav_section label="Today">
      <.nav_link navigate={~p"/home"} icon="hero-home" active={@active == :home}>Home</.nav_link>
      <.nav_link navigate={~p"/ask"} icon="hero-sparkles" active={@active == :ask}>Ask</.nav_link>
      <.nav_link
        navigate={~p"/ready-to-post"}
        icon="hero-inbox-stack"
        active={@active == :ready_to_post}
      >
        Ready to Post
      </.nav_link>
      <.nav_link navigate={~p"/queue"} icon="hero-queue-list" active={@active == :queue}>
        Queue
      </.nav_link>
      <.nav_link navigate={~p"/articles"} icon="hero-document-text" active={@active == :articles}>
        Articles
      </.nav_link>
      <.nav_link navigate={~p"/engage"} icon="hero-chat-bubble-left-right" active={@active == :engage}>
        Engage
      </.nav_link>
    </.nav_section>

    <.nav_section label="Create">
      <.nav_link navigate={~p"/workers"} icon="hero-bolt" active={@active == :workers}>
        Workers
      </.nav_link>
    </.nav_section>

    <.nav_section label="Research">
      <.nav_link navigate={~p"/inspiration"} icon="hero-light-bulb" active={@active == :inspiration}>
        Inspiration
      </.nav_link>
      <.nav_link navigate={~p"/analytics"} icon="hero-chart-bar" active={@active == :analytics}>
        Analytics
      </.nav_link>
    </.nav_section>

    <.nav_section label="Network">
      <.nav_link navigate={~p"/signals"} icon="hero-signal" active={@active == :signals}>
        Signals
      </.nav_link>
      <.nav_link navigate={~p"/contacts"} icon="hero-users" active={@active == :contacts}>
        Contacts
      </.nav_link>
      <.nav_link navigate={~p"/dms"} icon="hero-envelope" active={@active == :dms}>DMs</.nav_link>
    </.nav_section>

    <.nav_section label="Settings">
      <.nav_link navigate={~p"/voice"} icon="hero-microphone" active={@active == :voice}>
        Voice
      </.nav_link>
      <.nav_link navigate={~p"/settings"} icon="hero-calendar-days" active={@active == :settings}>
        Schedule
      </.nav_link>
      <.nav_link navigate={~p"/accounts"} icon="hero-user-circle" active={@active == :accounts}>
        Accounts
      </.nav_link>
      <.nav_link navigate={~p"/upgrade"} icon="hero-credit-card" active={@active == :upgrade}>
        Plan
      </.nav_link>
    </.nav_section>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp nav_section(assigns) do
    ~H"""
    <div>
      <div class="nb-eyebrow px-2.5 pb-1.5 text-[10px]">{@label}</div>
      <div class="flex flex-col gap-px">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, default: nil
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class="nav-link" aria-current={@active && "page"}>
      <.icon :if={@icon} name={@icon} class="size-4" />
      <span class="truncate">{render_slot(@inner_block)}</span>
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
          if(credits.limit > 0, do: min(round(credits.used / credits.limit * 100), 100), else: 0)
      )

    ~H"""
    <.link navigate={~p"/upgrade"} class="group block">
      <div class="flex items-baseline justify-between">
        <span class="text-[11px] text-faint">Credits</span>
        <span class="nb-mono text-[11px] group-hover:text-primary">
          {@credits.used} / {@credits.limit}
        </span>
      </div>
      <div class="meter mt-2"><i style={"width: #{@pct}%"} /></div>
    </.link>
    """
  end

  attr :current_user, :map, default: nil
  attr :current_x_account, :map, default: nil
  attr :quota, :map, default: nil

  defp account_footer(assigns) do
    ~H"""
    <div :if={@current_user} class="flex items-center gap-2">
      <.avatar src={@current_x_account && @current_x_account.avatar_url} size="size-6" />
      <div class="min-w-0 flex-1 leading-tight">
        <p class="truncate text-[12px] font-medium">
          {(@current_x_account && @current_x_account.display_name) || @current_user.name}
        </p>
        <p class="truncate text-[11px] text-faint">
          <span :if={@current_x_account}>@{@current_x_account.handle}</span>
          <span :if={!@current_x_account}>Not connected</span>
        </p>
      </div>
      <.link href={~p"/sign-out"} method="delete" class="icon-act" title="Sign out">
        <.icon name="hero-arrow-right-start-on-rectangle-mini" class="size-4" />
      </.link>
    </div>
    <p :if={tier_label(assigns)} class="text-[11px] text-faint">
      {tier_label(assigns)}
    </p>
    """
  end

  # A paying subscription labels itself, because only it knows about
  # trials. Everyone else gets the tier actually in force — on an
  # instance with SUPERX_DEFAULT_TIER set they really do have those
  # limits, and "Free" beside a 4000-credit meter reads as a bug.
  defp tier_label(assigns) do
    sub = get_in(assigns, [:current_user, Access.key(:subscription)])

    cond do
      match?(%Subscription{}, sub) and Subscription.entitled?(sub) -> Subscription.label(sub)
      is_binary(assigns[:quota][:tier]) -> String.capitalize(assigns.quota.tier)
      match?(%Subscription{}, sub) -> Subscription.label(sub)
      true -> nil
    end
  end

  @doc """
  Page header: title, optional description, optional trailing action.
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :action

  def page_header(assigns) do
    ~H"""
    <header class="page-header">
      <div class="flex items-start justify-between gap-6">
        <div>
          <h1 class="text-[1.75rem] font-semibold leading-[1.15] tracking-[-0.03em]">{@title}</h1>
          <p :if={@description} class="mt-2 max-w-[56ch] text-muted-foreground">{@description}</p>
        </div>
        <div :if={@action != []} class="shrink-0">{render_slot(@action)}</div>
      </div>
    </header>
    """
  end

  @doc """
  A round avatar.

  When there is no image the fallback is the author's initial rather than
  an empty grey disc, so a column of contacts without avatars still reads
  as a list of distinct people.
  """
  attr :src, :string, default: nil
  attr :name, :string, default: nil, doc: "used for the initial when src is missing"
  attr :size, :string, default: "size-6"
  attr :class, :string, default: ""

  def avatar(assigns) do
    ~H"""
    <img
      :if={@src}
      src={@src}
      alt=""
      loading="lazy"
      class={["shrink-0 rounded-full object-cover bg-muted", @size, @class]}
    />
    <div
      :if={!@src}
      aria-hidden="true"
      class={[
        "shrink-0 rounded-full bg-muted grid place-items-center",
        "text-[0.65em] font-medium uppercase text-faint select-none",
        @size,
        @class
      ]}
    >
      {initial(@name)}
    </div>
    """
  end

  defp initial(nil), do: ""

  defp initial(name) do
    name
    |> String.trim_leading("@")
    |> String.first()
    |> Kernel.||("")
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
  Light / dark switch. A text action, like everything else.
  """
  def theme_toggle(assigns) do
    ~H"""
    <button type="button" class="act text-xs" phx-click={JS.dispatch("phx:set-theme")}>
      Theme
    </button>
    """
  end

  @doc """
  The SuperX lockup: mark plus wordmark.

  The mark is an X crossing whose rising arm stops short, with the ember
  tick completing it — the same "growth that resolves into something
  published" idea the product is built around, and the same two-colour
  rule (ink plus one ember) as everything else. It is drawn inline rather
  than loaded from `/images/logo.svg` so it inherits `currentColor` and
  works in both themes; the file exists for the favicon and for anywhere
  outside the app that needs a static asset.
  """
  attr :class, :string, default: ""
  attr :mark_only, :boolean, default: false

  def logo(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-2", @class]}>
      <.logo_mark class="size-[1.15em] shrink-0" />
      <span :if={!@mark_only} class="inline-flex items-baseline gap-1">
        <span class="nb-display font-semibold tracking-[-0.03em]">superx</span>
        <span class="leading-none text-primary">·</span>
      </span>
    </span>
    """
  end

  @doc "The bare mark, for favicons, avatars and tight chrome."
  attr :class, :string, default: "size-4"

  def logo_mark(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="none" aria-hidden="true" class={@class}>
      <path
        d="M4.75 4.75 19.25 19.25"
        stroke="currentColor"
        stroke-width="2.5"
        stroke-linecap="round"
      />
      <path
        d="M4.75 19.25 13.6 10.4"
        stroke="currentColor"
        stroke-width="2.5"
        stroke-linecap="round"
      />
      <circle cx="18.25" cy="5.75" r="3" fill="var(--primary)" />
    </svg>
    """
  end
end
