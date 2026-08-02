# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :superx,
  namespace: SuperX,
  ecto_repos: [SuperX.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# pgvector needs a custom Postgrex type module to encode/decode `vector`.
config :superx, SuperX.Repo, types: SuperX.PostgrexTypes

# Configure the endpoint
config :superx, SuperXWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SuperXWeb.ErrorHTML, json: SuperXWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SuperX.PubSub,
  live_view: [signing_salt: "PBRjH/wC"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :superx, SuperX.Mailer, adapter: Swoosh.Adapters.Local

# Background jobs. Postgres is the queue — no Redis, no external scheduler.
config :superx, Oban,
  repo: SuperX.Repo,
  queues: [
    # Publishing is latency-sensitive and must not be starved by bulk work.
    publishing: 20,
    # LLM calls: generation, voice profiles, reply drafts.
    generation: 10,
    # Corpus ingestion and watch agent polling.
    ingestion: 10,
    # Private inboxes, analytics snapshots, token refresh, housekeeping.
    maintenance: 5
  ],
  plugins: [
    # Keep completed jobs for a week so the Failed tab has history.
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Rescue jobs orphaned by a node dying mid-publish.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       # Fire due queue slots every minute.
       {"* * * * *", SuperX.Workers.QueueDispatcher},
       # Refresh X OAuth tokens before they expire.
       {"*/15 * * * *", SuperX.Workers.TokenRefresher},
       # Daily analytics snapshot per connected account.
       {"10 0 * * *", SuperX.Workers.AnalyticsSnapshot},
       # Refresh the corpus before the shelf is written from it.
       {"0 1 * * *", SuperX.Workers.CorpusRefresh},
       # Top up each user's Ready to Post shelf overnight.
       {"30 2 * * *", SuperX.Workers.ShelfTopUp},
       # Dispatch user-configured content batches in their local time.
       {"* * * * *", SuperX.Workers.ContentWorkerDispatcher},
       # Poll mentions so the Engage inbox is current each morning.
       {"*/20 * * * *", SuperX.Workers.MentionSync},
       # Private inbox volume is small enough for X's user-auth read quota.
       {"*/5 * * * *", SuperX.Workers.DMSync},
       # Refresh metrics on recent posts so automations can gate on them.
       {"*/30 * * * *", SuperX.Workers.PostMetrics},
       # Fire post automations (reposts, plugs, deletions) that have come due.
       {"*/15 * * * *", SuperX.Workers.AutomationMonitor},
       # Run the Signals watches that are due.
       {"15 */2 * * *", SuperX.Workers.SignalSweep},
       # Roll monthly/daily quota windows.
       {"0 0 * * *", SuperX.Workers.QuotaRoller}
     ]}
  ]

# LLM provider, base URL, keys and model names are all resolved at runtime
# from the environment — see config/runtime.exs.

# X API. Public reads come from twitterapi.io; private DMs stay here.
config :superx, SuperX.X,
  api_base: "https://api.x.com/2",
  oauth_authorize_url: "https://twitter.com/i/oauth2/authorize",
  oauth_token_url: "https://api.twitter.com/2/oauth2/token",
  # Asking for a scope the X app isn't permitted for fails the whole
  # authorisation. runtime.exs adds the DM scopes only when the operator
  # has deliberately enabled the matching permission tier.
  #
  # media.write is separate from tweet.write: attaching an image needs its
  # own upload call first, and without this scope that call 403s while
  # posting text carries on working — so the gap only appears on the first
  # post that has an attachment.
  scopes: ~w(tweet.read tweet.write users.read offline.access follows.read like.read media.write)

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  superx: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  superx: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Real time zone data — publishing slots are defined in the user's local
# time and must survive DST transitions.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
