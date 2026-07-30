defmodule SuperXWeb.UpgradeLive do
  @moduledoc """
  Plan comparison, current usage, and checkout.
  """

  use SuperXWeb, :live_view

  alias SuperX.Billing
  alias SuperX.Billing.Plan

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(page_title: "Upgrade")
     |> assign(:interval, :month)
     |> assign(:plans, Plan.paid())
     |> assign(:tier, Billing.tier(user))
     |> assign(:subscription, Billing.get_subscription(user))
     |> assign(:billing_configured, Billing.Checkout.configured?())
     |> assign(:open_instance, Billing.open_instance?())
     |> assign(:usage, Billing.quota_snapshot(user))}
  end

  @impl true
  def handle_event("set_interval", %{"interval" => interval}, socket) do
    {:noreply, assign(socket, :interval, String.to_existing_atom(interval))}
  end

  def handle_event("checkout", %{"tier" => tier}, socket) do
    case Billing.Checkout.create_session(socket.assigns.current_user, tier, socket.assigns.interval) do
      {:ok, url} ->
        {:noreply, redirect(socket, external: url)}

      {:error, :not_configured} ->
        {:noreply, put_flash(socket, :error, "Billing isn't configured on this server.")}

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
    <div class="space-y-8">
      <div>
        <h1 class="text-2xl font-bold tracking-tight">Plans</h1>
        <p class="mt-1 text-sm" style="color: var(--text-secondary)">
          You're on {Plan.get(@tier).name}.
        </p>
      </div>

      <section class="card p-5">
        <div class="flex items-baseline justify-between">
          <h2 class="font-semibold">This window</h2>
          <button
            :if={@subscription && @subscription.provider_customer_id}
            phx-click="manage"
            class="btn btn-ghost btn-sm"
          >
            Manage billing
          </button>
        </div>

        <div class="mt-4 space-y-4">
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

      <div class="flex justify-center">
        <div
          class="inline-flex rounded-full border p-0.5"
          style="border-color: var(--border-strong); background-color: var(--surface-sunken)"
        >
          <button
            :for={{value, label} <- [{"month", "Monthly"}, {"year", "Yearly · 2 months free"}]}
            phx-click="set_interval"
            phx-value-interval={value}
            class={[
              "rounded-full px-4 py-1.5 text-sm font-medium",
              to_string(@interval) == value && "bg-[var(--surface-raised)] shadow-sm"
            ]}
          >
            {label}
          </button>
        </div>
      </div>

      <div :if={!@billing_configured} class="card p-4 text-sm">
        <p class="font-semibold">Billing isn't configured</p>
        <p class="mt-1" style="color: var(--text-secondary)">
          Set <code class="font-mono text-xs">STRIPE_SECRET_KEY</code>
          and the price ids to accept payments.
          <span :if={!@open_instance}>
            On a private instance, set
            <code class="font-mono text-xs">SUPERX_DEFAULT_TIER=ultra</code>
            instead to lift every limit without payment.
          </span>
          <span :if={@open_instance}>
            This instance grants {Plan.get(@tier).name} limits to everyone.
          </span>
        </p>
      </div>

      <div class="grid gap-5 lg:grid-cols-3">
        <section
          :for={plan <- @plans}
          class={[
            "card flex flex-col p-6",
            plan.tier == "advanced" && "ring-2 ring-ember-500"
          ]}
        >
          <div class="flex items-center justify-between">
            <h3 class="font-bold">{plan.name}</h3>
            <span :if={plan.tier == "advanced"} class="badge badge-ember">Most popular</span>
            <span :if={plan.tier == @tier} class="badge">Current</span>
          </div>

          <p class="mt-1 text-sm" style="color: var(--text-secondary)">{plan.tagline}</p>

          <p class="mt-4">
            <span class="text-3xl font-bold tabular-nums">
              ${price(plan, @interval)}
            </span>
            <span class="text-sm" style="color: var(--text-muted)">
              /{if @interval == :month, do: "month", else: "year"}
            </span>
          </p>

          <ul class="mt-5 flex-1 space-y-2.5">
            <li :for={feature <- plan.features} class="flex items-start gap-2 text-sm">
              <.icon name="hero-check" class="mt-0.5 size-4 shrink-0 text-ember-600" />
              <span>{feature}</span>
            </li>
          </ul>

          <button
            :if={plan.tier != @tier and @billing_configured}
            phx-click="checkout"
            phx-value-tier={plan.tier}
            class={["btn mt-6", if(plan.tier == "advanced", do: "btn-primary", else: "btn-secondary")]}
          >
            {if Plan.upgrade?(@tier, plan.tier), do: "Upgrade", else: "Switch"} to {plan.name}
          </button>
          <p :if={plan.tier == @tier} class="mt-6 text-center text-sm" style="color: var(--text-muted)">
            Your current plan
          </p>
        </section>
      </div>
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
      <div class="flex items-baseline justify-between text-sm">
        <span class="font-medium">{@label}</span>
        <span class="tabular-nums" style="color: var(--text-muted)">
          {@usage.used} / {@usage.limit}
        </span>
      </div>
      <div class="mt-1.5 h-1.5 overflow-hidden rounded-full" style="background-color: var(--surface-sunken)">
        <div class="h-full rounded-full bg-ember-500" style={"width: #{@pct}%"} />
      </div>
      <p :if={@usage.resets_at} class="mt-1 text-xs" style="color: var(--text-muted)">
        Resets {Calendar.strftime(@usage.resets_at, "%-d %b")}
      </p>
    </div>
    """
  end

  defp price(plan, :month), do: div(plan.monthly_cents, 100)
  defp price(plan, :year), do: div(plan.yearly_cents, 100)
end
