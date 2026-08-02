import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :superx, SuperX.Repo,
  username: System.get_env("PGUSER", System.get_env("USER")),
  socket_dir: System.get_env("PGSOCKET", "/var/run/postgresql"),
  database: "superx_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :superx, SuperXWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "sdzy7SLDcS+kWejqIEBMQ/Kt1lAN4PC11QXroKMIV4xvyuI3q+bOIAcLyTxNDm6I",
  server: false

# In test we don't send emails
config :superx, SuperX.Mailer, adapter: Swoosh.Adapters.Test

# Keep job insertion available for assertions without starting queues or cron
# processes against SQL Sandbox connections owned by individual tests.
config :superx, Oban, queues: false, plugins: false

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Fixtures build bands of a handful of posts. The production floor of 30
# exists to stop a thin band producing a meaningless multiple; the tests
# that assert the floor itself set it explicitly.
config :superx, :min_outlier_baseline_sample, 1

# Stub the HTTP wire in tests rather than reaching the real APIs.
config :superx, twitter_api_plug: {Req.Test, SuperX.TwitterAPI}
config :superx, ai_plug: {Req.Test, SuperX.AI}
config :superx, x_plug: {Req.Test, SuperX.X}
config :superx, stripe_plug: {Req.Test, SuperX.Billing.Checkout}
