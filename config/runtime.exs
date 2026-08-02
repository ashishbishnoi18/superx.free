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

# `System.get_env/2` only falls back when a variable is *unset*, but an
# unset variable is rare in practice: Docker Compose passes every key it
# knows about, so a blank line in .env arrives as "". That empty string
# is truthy, so it shadows the default — an empty model name reaches the
# provider, and an empty integer raises. Treat blank as absent.
env = fn name, default ->
  case System.get_env(name) do
    nil -> default
    "" -> default
    value -> value
  end
end

config :superx, SuperXWeb.Endpoint, http: [port: String.to_integer(env.("PORT", "4000"))]

# A mounted path keeps queued media across container rebuilds. Development
# stays in the source tree so previews are easy to inspect and clear.
config :superx, SuperX.Media,
  path:
    env.(
      "SUPERX_UPLOADS_DIR",
      if(config_env() == :prod,
        do: "/app/uploads",
        else: Path.expand("../priv/uploads", __DIR__)
      )
    )

# --- Secrets shared by every environment -----------------------------------

# X OAuth2 app credentials. Without these, login is disabled and the app
# boots into a setup screen explaining what to configure.
config :superx, SuperX.X,
  client_id: env.("X_CLIENT_ID", nil),
  client_secret: env.("X_CLIENT_SECRET", nil),
  redirect_uri: env.("X_REDIRECT_URI", "http://localhost:4000/auth/x/callback"),
  dm_enabled: env.("SUPERX_ENABLE_DMS", "false") in ~w(1 true)

# LLM provider. Both speak Anthropic's Messages API — DeepSeek serves it
# at /anthropic with the same header and content-block format — so this is
# a base URL and two model names, not a second client.
#
# Models are overridable individually: the writer wants quality (it decides
# whether a post sounds like the user), the utility model runs the
# high-volume classification and scoring where cheap is right.
llm =
  case env.("SUPERX_LLM_PROVIDER", "anthropic") do
    "deepseek" ->
      %{
        provider: "deepseek",
        base_url: "https://api.deepseek.com/anthropic",
        api_key: env.("DEEPSEEK_API_KEY", nil),
        writer_model: env.("SUPERX_WRITER_MODEL", "deepseek-v4-pro"),
        utility_model: env.("SUPERX_UTILITY_MODEL", "deepseek-v4-flash")
      }

    _anthropic ->
      %{
        provider: "anthropic",
        base_url: "https://api.anthropic.com",
        api_key: env.("ANTHROPIC_API_KEY", nil),
        writer_model: env.("SUPERX_WRITER_MODEL", "claude-sonnet-5"),
        utility_model: env.("SUPERX_UTILITY_MODEL", "claude-haiku-4-5-20251001")
      }
  end

config :superx, SuperX.AI,
  provider: llm.provider,
  base_url: llm.base_url,
  api_key: llm.api_key,
  writer_model: llm.writer_model,
  utility_model: llm.utility_model,
  embedding_model: "voyage-3-large",
  embedding_dimensions: 1024,
  voyage_api_key: env.("VOYAGE_API_KEY", nil)

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
  api_key: env.("TWITTERAPI_IO_KEY", nil),
  min_interval_ms: String.to_integer(env.("TWITTERAPI_IO_MIN_INTERVAL_MS", "5000"))

# Tier granted to users without a paid subscription. `free` suits a
# multi-tenant deployment; a private instance paying its own LLM bill
# should set this to `ultra` so it isn't throttled by its own quotas.
config :superx, :default_tier, env.("SUPERX_DEFAULT_TIER", "free")

# Token encryption key. Required in prod; in dev/test it falls back to a
# key derived from secret_key_base so a fresh checkout just runs.
vault_key =
  case env.("SUPERX_VAULT_KEY", nil) do
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
    env.("DATABASE_URL", nil) ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :superx, SuperX.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(env.("POOL_SIZE", "10")),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    env.("SECRET_KEY_BASE", nil) ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = env.("PHX_HOST", "example.com")

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
