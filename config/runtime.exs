import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/superx start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :superx, SuperXWeb.Endpoint, server: true
end

config :superx, SuperXWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# --- Secrets shared by every environment -----------------------------------

# X OAuth2 app credentials. Without these, login is disabled and the app
# boots into a setup screen explaining what to configure.
config :superx, SuperX.X,
  client_id: System.get_env("X_CLIENT_ID"),
  client_secret: System.get_env("X_CLIENT_SECRET"),
  redirect_uri: System.get_env("X_REDIRECT_URI", "http://localhost:4000/auth/x/callback")

config :superx, SuperX.AI,
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  voyage_api_key: System.get_env("VOYAGE_API_KEY")

# twitterapi.io — the read side. Without a key the corpus, mentions, and
# Signals stay empty and the rest of the app works normally.
#
# min_interval_ms paces calls to your plan's QPS. The free tier is
# advertised at 0.2 QPS but measured tighter than that in practice — even
# 6s spacing draws the occasional 429 on a first attempt. That's handled:
# retries back off at this interval, so throughput self-corrects to roughly
# one call per 11s rather than failing. Lower this once you're on a paid
# plan; raising QPS beyond what you pay for only buys 429s.
config :superx, SuperX.TwitterAPI,
  api_key: System.get_env("TWITTERAPI_IO_KEY"),
  min_interval_ms: String.to_integer(System.get_env("TWITTERAPI_IO_MIN_INTERVAL_MS", "5000"))

config :superx, SuperX.Billing,
  stripe_secret_key: System.get_env("STRIPE_SECRET_KEY"),
  stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET")

# Tier granted to users without a paid subscription. `free` suits a
# multi-tenant deployment; a private instance paying its own LLM bill
# should set this to `ultra` so it isn't throttled by its own quotas.
config :superx,
       :default_tier,
       System.get_env("SUPERX_DEFAULT_TIER", "free")

# Stripe price ids per {tier, interval}. Only the pairs you configure are
# offered, so a partial setup degrades to fewer plans rather than errors.
config :superx, SuperX.Billing.Checkout,
  price_ids:
    for(
      tier <- ~w(pro advanced ultra),
      interval <- ~w(month year),
      id = System.get_env("STRIPE_PRICE_#{String.upcase(tier)}_#{String.upcase(interval)}"),
      is_binary(id) and id != "",
      into: %{},
      do: {{tier, interval}, id}
    )

# Token encryption key. Required in prod; in dev/test it falls back to a
# key derived from secret_key_base so a fresh checkout just runs.
vault_key =
  case System.get_env("SUPERX_VAULT_KEY") do
    nil ->
      if config_env() == :prod do
        raise """
        environment variable SUPERX_VAULT_KEY is missing.

        Generate one with:

            mix superx.gen.vault_key

        Losing this key makes every stored X token undecryptable and
        forces all users to reconnect their accounts.
        """
      else
        salt = Application.get_env(:superx, SuperXWeb.Endpoint)[:secret_key_base] || "dev"
        :crypto.hash(:sha256, "superx.vault.dev." <> salt)
      end

    encoded ->
      case Base.decode64(encoded) do
        {:ok, <<key::binary-32>>} ->
          key

        _ ->
          raise "SUPERX_VAULT_KEY must be exactly 32 bytes, base64-encoded"
      end
  end

config :superx, vault_key: vault_key

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :superx, SuperX.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :superx, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :superx, SuperXWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :superx, SuperXWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :superx, SuperXWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :superx, SuperX.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
