defmodule SuperXWeb.BillingLive do
  @moduledoc """
  One paid plan at two prices.

  There is no tier ladder and nothing is gated behind payment: the software
  is the same either way. The prices differ in whose API keys do the work,
  which is a real cost difference rather than an invented one.

  On a self-hosted instance Stripe is not configured, so this page says so
  instead of offering a checkout that cannot complete.
  """

  use SuperXWeb, :live_view

  alias SuperX.Billing
  alias SuperX.Billing.{Stripe, Subscription}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:page_title, "Billing")
     |> assign(:configured, Stripe.configured?())
     |> assign(:prices, Stripe.prices())
     |> assign(:subscription, Billing.get_subscription(user))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :just_paid, params["checkout"] == "done")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page_header title="Billing" description="One plan. Cancel whenever you like." />

    <div :if={@just_paid} class="post mb-8">
      <p>
        Thank you. If the status below still says free, Stripe is a moment behind —
        it updates on its own.
      </p>
    </div>

    <div :if={not @configured} class="post">
      <p class="text-faint">
        This instance has no payment configured, which is the normal state for a
        self-hosted copy. Everything already works; there is nothing to buy.
      </p>
    </div>

    <div :if={@configured}>
      <div class="post mb-8">
        <p class="nb-mono text-faint">Current plan</p>
        <p class="mt-1 text-lg">{plan_label(@subscription)}</p>
        <p :if={renews_at(@subscription)} class="mt-1 text-faint">
          {renewal_sentence(@subscription)}
        </p>

        <.link
          :if={@subscription && @subscription.provider_customer_id}
          navigate={~p"/billing/portal"}
          class="act mt-4 inline-block"
        >
          Manage payment and cancellation
        </.link>
      </div>

      <div class="grid gap-4 sm:grid-cols-2">
        <div :for={price <- @prices} class="post">
          <p class="nb-mono text-faint">{price.name}</p>
          <p class="mt-1 text-2xl">${div(price.cents, 100)}<span class="text-faint">/month</span></p>
          <p class="mt-2 text-muted-foreground">{price.blurb}</p>

          <form action={~p"/billing/checkout"} method="post" class="mt-4">
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <input type="hidden" name="price" value={price.key} />
            <button type="submit" class="act act-key">Subscribe</button>
          </form>
        </div>
      </div>

      <p class="mt-8 max-w-[60ch] text-faint">
        Paying does not unlock features. It pays for the machine this runs on and,
        on the first price, the API bills it runs up. Self-host it and pay nothing.
      </p>
    </div>
    """
  end

  defp plan_label(%Subscription{} = sub) do
    if Subscription.entitled?(sub), do: "Paid — #{sub.status}", else: "Free"
  end

  defp plan_label(_none), do: "Free"

  defp renews_at(%Subscription{current_period_end: %DateTime{} = at}), do: at
  defp renews_at(_none), do: nil

  defp renewal_sentence(%Subscription{cancel_at_period_end: true} = sub) do
    "Ends #{Calendar.strftime(sub.current_period_end, "%-d %B %Y")}."
  end

  defp renewal_sentence(%Subscription{} = sub) do
    "Renews #{Calendar.strftime(sub.current_period_end, "%-d %B %Y")}."
  end
end
