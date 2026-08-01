defmodule SuperXWeb.UpgradeLive do
  @moduledoc """
  Plan comparison, current usage, and checkout.
  """

  use SuperXWeb, :live_view

  alias SuperX.Billing
  alias SuperX.Billing.Plan
  alias SuperX.Teams

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    interval = :month
    team_owner = Teams.owner_for(user)
    seat_count = if team_owner, do: 0, else: Billing.seat_count(user)

    {:ok,
     socket
     |> assign(page_title: "Upgrade")
     |> assign(:interval, interval)
     |> assign(:plans, Plan.paid())
     |> assign(:tier, Billing.tier(user))
     |> assign(:subscription, Billing.get_subscription(user))
     |> assign(:billing_configured, Billing.Checkout.configured?())
     |> assign(:open_instance, Billing.open_instance?())
     |> assign(:usage, Billing.quota_snapshot(user))
     |> assign(:team_owner, team_owner)
     |> assign(:seat_count, seat_count)}
  end

  @impl true
  def handle_event("set_interval", %{"interval" => interval}, socket) do
    {:noreply, assign(socket, :interval, String.to_existing_atom(interval))}
  end

  def handle_event("checkout", %{"tier" => tier}, socket) do
    case Billing.Checkout.create_session(
           socket.assigns.current_user,
           tier,
           socket.assigns.interval
         ) do
      {:ok, url} ->
        {:noreply, redirect(socket, external: url)}

      {:error, :not_configured} ->
        {:noreply, put_flash(socket, :error, "Billing isn't configured on this server.")}

      {:error, :team_member} ->
        {:noreply, put_flash(socket, :error, "Your team owner manages this plan.")}

      {:error, {:no_seat_price_for, _tier, _interval}} ->
        {:noreply, put_flash(socket, :error, "Seat billing isn't configured for that plan.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "We couldn't start checkout. Try again shortly.")}
    end
  end

  def handle_event("manage", _params, socket) do
    case Billing.Checkout.portal_url(socket.assigns.current_user) do
      {:ok, url} -> {:noreply, redirect(socket, external: url)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't open the billing portal.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header
      title="Plan"
      description={
        if(@team_owner,
          do:
            "#{@team_owner.name || "Your team owner"} supplies your #{Plan.get(@tier).name} entitlement.",
          else: "You're on #{Plan.get(@tier).name}."
        )
      }
    >
      <:action>
        <button
          :if={!@team_owner && @subscription && @subscription.provider_customer_id}
          phx-click="manage"
          class="act whitespace-nowrap text-xs"
        >
          Manage billing
        </button>
      </:action>
    </Layouts.page_header>

    <section class="mb-10">
      <p class="nb-eyebrow mb-4">This window</p>
      <div class="flex flex-col gap-5">
        <.usage_bar
          :for={
            {key, label} <- [
              {"credits_month", "AI credits"},
              {"posts_month", "Posts"},
              {"replies_day", "Assisted replies"}
            ]
          }
          label={label}
          usage={Map.get(@usage, key)}
        />
      </div>
    </section>

    <section id="seat-pricing" class="mb-10 border-y border-border py-6">
      <div class="grid grid-cols-1 gap-7 sm:grid-cols-[14rem_minmax(0,1fr)]">
        <div>
          <p class="nb-eyebrow">Team seats</p>
          <p
            id="seat-count"
            data-seat-count={if(@team_owner, do: 1, else: @seat_count)}
            data-discount={if(@team_owner, do: nil, else: Billing.seat_discount_percent(@seat_count))}
            class="nb-display mt-2 text-[1.5rem] tabular-nums"
          >
            {if @team_owner, do: "1 managed seat", else: "#{@seat_count} #{seat_label(@seat_count)}"}
          </p>
        </div>

        <div :if={@team_owner}>
          <p class="text-muted-foreground">
            Billing belongs to {@team_owner.name || @team_owner.email || "your team owner"}. Your
            usage remains in your own quota rows and is not pooled with theirs.
          </p>
        </div>

        <div :if={!@team_owner}>
          <p :if={@seat_count == 0} class="text-muted-foreground">
            No billed member seats yet. Accepted invitations from Accounts will appear here.
          </p>
          <p :if={@seat_count > 0} class="text-muted-foreground">
            {@seat_count} accepted {seat_label(@seat_count)} use your tier. The current volume
            reduction is <span class="nb-mono text-[12px] text-foreground">{Billing.seat_discount_percent(@seat_count)}%</span>.
          </p>
          <p class="nb-mono mt-3 text-[11px] leading-[1.7] text-faint">
            1 member · list price<br /> 2–10 members · 25% off<br /> 11–50 members · 30% off<br />
            51+ members · 35% off
          </p>
        </div>
      </div>
    </section>

    <p :if={!@billing_configured} class="mb-8 max-w-[60ch] text-muted-foreground">
      Billing isn't configured. Set
      <code class="nb-mono text-[12px] text-foreground">STRIPE_SECRET_KEY</code>
      and the price ids to accept payments.
      <span :if={!@open_instance}>
        On a private instance, set
        <code class="nb-mono text-[12px] text-foreground">SUPERX_DEFAULT_TIER=ultra</code>
        instead to lift every limit without payment.
      </span>
      <span :if={@open_instance}>
        This instance grants {Plan.get(@tier).name} limits to everyone.
      </span>
    </p>

    <div class="mb-6 flex gap-5 text-xs">
      <button
        :for={{value, label} <- [{"month", "Monthly"}, {"year", "Yearly · 2 months free"}]}
        phx-click="set_interval"
        phx-value-interval={value}
        class={if to_string(@interval) == value, do: "act-key", else: "act"}
      >
        {label}
      </button>
    </div>

    <div class="flex flex-col">
      <section
        :for={plan <- @plans}
        class="grid grid-cols-1 gap-7 border-t border-border py-6 last:border-b sm:grid-cols-[14rem_minmax(0,1fr)]"
      >
        <div>
          <div class="flex items-baseline gap-2">
            <h3 class="text-[15px] font-semibold">{plan.name}</h3>
            <span :if={plan.tier == @tier} class="nb-mono text-[11px] text-primary">current</span>
          </div>
          <p class="mt-1 text-[12px] leading-[1.6] text-faint">{plan.tagline}</p>
          <p class="nb-display mt-3 text-[1.5rem] font-semibold tracking-[-0.03em] tabular-nums">
            ${price(plan, @interval)}
            <span class="nb-mono text-[11px] font-normal text-faint">
              /{if @interval == :month, do: "mo", else: "yr"}
            </span>
          </p>
          <p
            :if={!@team_owner && @seat_count > 0}
            id={"#{plan.tier}-seat-price"}
            class="nb-mono mt-2 text-[11px] leading-[1.6] text-faint"
          >
            {seat_price_line(plan, @interval, @seat_count)}
          </p>
        </div>

        <div>
          <ul class="flex flex-col gap-1.5">
            <li :for={feature <- plan.features} class="text-muted-foreground">{feature}</li>
          </ul>

          <button
            :if={
              !@team_owner and plan.tier != @tier and
                Billing.Checkout.configured_for?(plan.tier, @interval, @seat_count)
            }
            phx-click="checkout"
            phx-value-tier={plan.tier}
            class="act-key mt-5 text-xs"
          >
            {if Plan.upgrade?(@tier, plan.tier), do: "Upgrade", else: "Switch"} to {plan.name}
          </button>
          <p
            :if={
              !@team_owner and plan.tier != @tier and @billing_configured and @seat_count > 0 and
                !Billing.Checkout.configured_for?(plan.tier, @interval, @seat_count)
            }
            class="mt-5 text-[12px] text-faint"
          >
            Seat billing is not configured for this plan and interval.
          </p>
        </div>
      </section>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :usage, :map, required: true

  defp usage_bar(assigns) do
    usage = assigns.usage || %{used: 0, limit: 0, remaining: 0, resets_at: nil}

    assigns =
      assign(assigns,
        usage: usage,
        pct: if(usage.limit > 0, do: min(round(usage.used / usage.limit * 100), 100), else: 0)
      )

    ~H"""
    <div>
      <div class="flex items-baseline justify-between">
        <span>{@label}</span>
        <span class="nb-mono text-[11px] text-muted-foreground">
          {@usage.used} / {@usage.limit}
        </span>
      </div>
      <div class="meter mt-2"><i style={"width: #{@pct}%"} /></div>
      <p :if={@usage.resets_at} class="nb-mono mt-1 text-[11px] text-faint">
        resets {Calendar.strftime(@usage.resets_at, "%-d %b")}
      </p>
    </div>
    """
  end

  defp price(plan, :month), do: div(plan.monthly_cents, 100)
  defp price(plan, :year), do: div(plan.yearly_cents, 100)

  defp seat_price_line(plan, interval, seat_count) do
    pricing = Billing.seat_pricing(plan.tier, interval, seat_count)
    combined_cents = Plan.price(plan.tier, interval) + pricing.total_cents

    "#{format_money(pricing.unit_cents)} each · #{format_money(combined_cents)} total with plan"
  end

  defp format_money(cents) do
    dollars = div(cents, 100)
    remainder = cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "$#{dollars}.#{remainder}"
  end

  defp seat_label(1), do: "member"
  defp seat_label(_count), do: "members"
end
