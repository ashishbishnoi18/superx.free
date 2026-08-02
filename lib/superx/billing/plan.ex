defmodule SuperX.Billing.Plan do
  @moduledoc """
  Static plan definitions: what each tier costs and what it allows.

  Limits live in code rather than the database because they are product
  decisions, not per-user state. `SuperX.Billing.Quota` reads them when
  it rolls a usage window.
  """

  @plans %{
    "free" => %{
      tier: "free",
      name: "Free",
      tagline: "Enough to see if it works for you",
      monthly_cents: 0,
      yearly_cents: 0,
      limits: %{
        x_accounts: 1,
        posts_month: 30,
        credits_month: 50,
        replies_day: 10,
        api_requests_minute: 15,
        signal_agents: 0,
        leads_day: 0
      },
      features: [
        "1 connected X account",
        "30 scheduled posts a month",
        "50 AI credits a month",
        "Voice-matched drafts",
        "Queue, analytics, and inspiration search"
      ]
    },
    "pro" => %{
      tier: "pro",
      name: "Pro",
      tagline: "The essentials to post consistently",
      monthly_cents: 2900,
      yearly_cents: 29_000,
      limits: %{
        x_accounts: 5,
        posts_month: 500,
        credits_month: 500,
        replies_day: 25,
        api_requests_minute: 60,
        signal_agents: 1,
        leads_day: 750
      },
      features: [
        "5 connected X accounts",
        "500 posts a month at your best times",
        "500 AI credits a month",
        "1 Signal agent · 750 leads a day",
        "Full corpus search",
        "API and MCP access"
      ]
    },
    "advanced" => %{
      tier: "advanced",
      name: "Advanced",
      tagline: "The full toolkit for serious growth",
      monthly_cents: 5900,
      yearly_cents: 59_000,
      limits: %{
        x_accounts: 5,
        posts_month: 1000,
        credits_month: 1500,
        replies_day: 75,
        api_requests_minute: 120,
        signal_agents: 3,
        leads_day: 3000
      },
      features: [
        "Everything in Pro",
        "1,500 AI credits a month on the best models",
        "75 assisted replies a day",
        "3 Signal agents · 3,000 leads a day",
        "Thread writer and article drafts"
      ]
    },
    "ultra" => %{
      tier: "ultra",
      name: "Ultra",
      tagline: "Top limits for power users",
      monthly_cents: 12_900,
      yearly_cents: 129_000,
      limits: %{
        x_accounts: 10,
        posts_month: 3000,
        credits_month: 4000,
        replies_day: 300,
        api_requests_minute: 300,
        signal_agents: 5,
        leads_day: 7500
      },
      features: [
        "Everything in Advanced",
        "10 connected X accounts",
        "4,000 AI credits a month",
        "300 assisted replies a day",
        "5 Signal agents · 7,500 leads a day",
        "Priority support"
      ]
    }
  }

  @ordered ~w(free pro advanced ultra)

  @doc "All plans in display order."
  def all, do: Enum.map(@ordered, &@plans[&1])

  @doc "Paid plans only — what the upgrade page shows."
  def paid, do: Enum.reject(all(), &(&1.tier == "free"))

  @doc "Look up a single plan by tier."
  def get(tier) when is_binary(tier), do: Map.get(@plans, tier, @plans["free"])

  @doc """
  The limit for `key` on `tier`. Accepts the key as an atom or a string,
  since quota keys are stored as strings in the database.

  Unknown keys return 0 rather than raising, so adding a new quota can't
  take the app down before its plan entry is filled in.
  """
  def limit(tier, key) when is_binary(tier) and is_atom(key) do
    get(tier).limits |> Map.get(key, 0)
  end

  def limit(tier, key) when is_binary(tier) and is_binary(key) do
    limits = get(tier).limits

    Enum.find_value(limits, 0, fn {limit_key, value} ->
      Atom.to_string(limit_key) == key && value
    end)
  end

  @doc "Price in cents for a tier on a billing interval."
  def price(tier, :month), do: get(tier).monthly_cents
  def price(tier, :year), do: get(tier).yearly_cents

  @doc "Whether `tier` is a real upgrade over `current`."
  def upgrade?(current, tier) do
    Enum.find_index(@ordered, &(&1 == tier)) > Enum.find_index(@ordered, &(&1 == current))
  end
end
