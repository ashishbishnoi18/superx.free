# Configuration reference

SuperX reads configuration when the release starts. Docker Compose reads
`.env`, expands `docker-compose.yml`, and passes the resulting values into the
containers. Restart the app after changing a value:

```bash
docker compose up -d --force-recreate app
```

Inspect the effective Compose configuration without starting anything:

```bash
docker compose config
```

Keep `.env` out of source control and readable only by its owner:

```bash
chmod 600 .env
```

Blank application variables are normally treated as unset. This matters
because Compose passes blank entries from `.env` as empty strings. The Stripe
price variables are the exception: the application reads them directly and
simply omits blank price IDs. Invalid integers still stop startup.

## Values required to boot production

These are the only values whose absence stops the Phoenix release. Compose
also requires `POSTGRES_PASSWORD` so it can construct `DATABASE_URL`.

| Variable | Required | Default | Purpose and missing behaviour |
|---|---|---|---|
| `DATABASE_URL` | Production | None | Ecto connection URL, for example `ecto://user:password@host/database`. A production release raises during startup if it is blank or absent. Compose constructs it from `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB`; setting `DATABASE_URL` in `.env` does not override that Compose expression. |
| `SECRET_KEY_BASE` | Production | None | Signs cookies and other Phoenix secrets. A production release raises during startup if it is blank or absent. Generate it with `mix phx.gen.secret`, or use the Docker command in [Setup](SETUP.md). Changing it invalidates existing signed browser cookies. |
| `SUPERX_VAULT_KEY` | Production | Derived key in development and test | Base64 encoding of exactly 32 bytes. It encrypts X access and refresh tokens and opaque XChat private-key blobs with AES-256-GCM. Production startup raises if it is absent, malformed, or the decoded value is not 32 bytes. Losing or changing it leaves stored X tokens and chat identities undecryptable; users must reconnect and encrypted chat history may become unreadable. Generate it with `mix superx.gen.vault_key` or `openssl rand -base64 32`. |

X OAuth is operationally required for a useful production instance, but it is
not a boot requirement. Without it, the server starts and shows a setup state.

## Web server and database

| Variable | Required | Default | Purpose and missing behaviour |
|---|---|---|---|
| `PHX_SERVER` | When starting a release without `bin/server` or `/app/bin/start` | Unset | Any present value enables the HTTP endpoint. The shipped release startup script sets it to `true`. If it is absent from a direct `bin/superx start`, the supervision tree and workers start but Phoenix does not listen for HTTP. |
| `PHX_HOST` | No | `example.com` in a direct production release; `localhost` in Compose | Public host used in generated HTTPS URLs. A wrong value causes incorrect absolute URLs and OAuth callbacks. It does not choose the bind interface. |
| `PORT` | No | `4000` | Internal HTTP port. Compose fixes it at `4000` and publishes host port 4000. Blank uses the default; a non-integer stops startup. |
| `SUPERX_UPLOADS_DIR` | No | `/app/uploads` in production; `priv/uploads` in development | Directory for durable images and GIFs attached to queued posts. The app creates it on the first upload. Compose fixes it at `/app/uploads` and mounts the `uploads` volume there. If the path is not writable, uploads fail. If it is not persistent, attachments disappear on a rebuild and scheduled posts later fail with “An attached file is missing from local storage.” |
| `POOL_SIZE` | No | `10` | Number of Ecto database connections per pool in production. Blank uses 10; a non-integer stops startup. Oban also uses the repository, so leave capacity for web requests and background work. |
| `ECTO_IPV6` | No | Disabled | `true` or `1` adds `:inet6` to PostgreSQL socket options. Any other value uses normal socket options. Enable it only when the database hostname resolves through IPv6. |
| `DNS_CLUSTER_QUERY` | No | Unset | DNS query passed to `DNSCluster` for distributed node discovery. Missing means `:ignore`. The shipped Compose deployment is one application node and does not need it. |

Production URLs use HTTPS and port 443 even though the application listens on
plain HTTP behind the reverse proxy. `config/prod.exs` trusts
`X-Forwarded-Proto` for HTTPS rewriting. See [Deployment](DEPLOYMENT.md).

## X OAuth and the official X API

| Variable | Required | Default | Purpose and missing behaviour |
|---|---|---|---|
| `X_CLIENT_ID` | No; needed for sign-in and X operations | None | OAuth 2.0 client ID. X sign-in is considered configured only when both this and `X_CLIENT_SECRET` are non-blank. If either is missing, `/auth/x` redirects home with “X sign-in is not configured on this server.” |
| `X_CLIENT_SECRET` | No; needed with `X_CLIENT_ID` | None | OAuth client secret. It is also used for token exchange, refresh, and revocation. Missing has the same degraded behaviour as a missing client ID. |
| `X_REDIRECT_URI` | No | `http://localhost:4000/auth/x/callback` in a direct release; `https://${PHX_HOST}/auth/x/callback` in Compose | Callback sent during OAuth. It must exactly match a callback registered in the X developer console. Missing uses the applicable default. A mismatch makes X refuse or fail the OAuth exchange. |
| `SUPERX_ENABLE_DMS` | No | `false` | Only the exact values `1` and `true` add `dm.read` and `dm.write` to new OAuth requests. Missing or any other value leaves DM access off, makes no DM sync calls, and shows setup instructions in the DMs screen. Enable the X app’s Direct Message permission tier first, then reconnect every existing account. |

Encrypted XChat support also needs Node 18+ and the pinned npm dependency in
`xchat/node_modules`. The Docker image includes both. A source checkout without
either logs at debug level, skips XChat, and keeps legacy DMs and the rest of
the application working.

The base OAuth scopes always include `tweet.read`, `tweet.write`, `users.read`,
`offline.access`, `follows.read`, `like.read`, and `media.write`. They are set in
code rather than environment variables. In particular, `media.write` is
separate from `tweet.write`; see [Troubleshooting](TROUBLESHOOTING.md#text-posts-work-but-posts-with-images-fail-with-403).

## Language models and embeddings

| Variable | Required | Default | Purpose and missing behaviour |
|---|---|---|---|
| `SUPERX_LLM_PROVIDER` | No | `anthropic` | Selects the Messages API endpoint. The exact value `deepseek` uses DeepSeek; every other value uses Anthropic. |
| `ANTHROPIC_API_KEY` | No | None | Used only when the selected provider is Anthropic. If it is missing, model-backed drafting, voice derivation, reply writing, lead scoring, article composition, and Ask are unavailable or skipped. Manual editing, queueing, publishing, and unscored public-data ingestion continue. |
| `DEEPSEEK_API_KEY` | No | None | Used only when `SUPERX_LLM_PROVIDER=deepseek`. Missing has the same degraded behaviour as a missing Anthropic key. Setting both provider keys does not create fallback: only the selected provider is called. |
| `SUPERX_WRITER_MODEL` | No | Anthropic: `claude-sonnet-5`; DeepSeek: `deepseek-v4-pro` | Model for voice-sensitive generation. Blank uses the provider default. A bad or unavailable model name does not stop startup; model calls fail and claimed application credits are refunded. |
| `SUPERX_UTILITY_MODEL` | No | Anthropic: `claude-haiku-4-5-20251001`; DeepSeek: `deepseek-v4-flash` | Model for classification, scoring, and other high-volume work. Blank uses the provider default. A bad model name fails those calls rather than startup. |
| `VOYAGE_API_KEY` | No | None | Enables 1,024-dimension embeddings with the hard-coded `voyage-3-large` model. Without it, ingestion skips embedding jobs and corpus retrieval uses PostgreSQL full-text search. If an embedding request fails during a query, search also falls back to full text. |

SuperX does not accept an arbitrary LLM base URL. The provider switch chooses
one of the two base URLs compiled into `config/runtime.exs`.

## Public X reads and corpus budget

| Variable | Required | Default | Purpose and missing behaviour |
|---|---|---|---|
| `TWITTERAPI_IO_KEY` | No | None | Key for twitterapi.io. Without it, corpus ingestion, mentions, topic feeds, follower/list watches, and other public reads through this client are skipped or return `:not_configured`. The application still starts. |
| `TWITTERAPI_IO_MIN_INTERVAL_MS` | No | `5000` in a direct release; `6000` in Compose | Minimum delay between twitterapi.io requests across the whole application node. Calls are serialized. Retries use multiples of the same interval. Blank uses the applicable default; a non-integer stops startup. Lower it only to match the rate paid for upstream. |
| `SUPERX_CORPUS_TOPICS_PER_RUN` | No | `20` | Maximum topics selected by the nightly corpus refresh. Up to 12 come from users’ voice topics; the rest rotate through built-in seed topics. Blank uses 20; a non-integer crashes the refresh job when read. Zero produces no topic jobs. |
| `SUPERX_CORPUS_POSTS_PER_TOPIC` | No | `40` | Maximum posts requested for each selected topic. Blank uses 40; a non-integer crashes the refresh job when read. With both defaults, a run asks for up to 800 posts. |

Every twitterapi.io response is passed through the persistent database cache.
See [Architecture](ARCHITECTURE.md#the-paid-read-cache) for freshness windows
and [FAQ](FAQ.md#what-do-the-external-services-cost) for the budget calculation.

## Billing and instance limits

Stripe is optional. A private installation normally leaves every `STRIPE_*`
value blank and sets `SUPERX_DEFAULT_TIER=ultra` if the operator does not want
the built-in free limits.

| Variable | Required | Default | Purpose and missing behaviour |
|---|---|---|---|
| `SUPERX_DEFAULT_TIER` | No | `free` | Tier used when a user has no entitled paid subscription. Supported useful values are `free`, `pro`, `advanced`, and `ultra`. Unknown values fall back to free limits in plan lookups, although the instance still labels itself open because the string is not `free`; use only a supported value. |
| `STRIPE_SECRET_KEY` | No | None | Authenticates Stripe Checkout and billing-portal calls. Checkout is enabled only when this is present and at least one base price ID is configured. Missing leaves billing disabled; accounts use `SUPERX_DEFAULT_TIER`. |
| `STRIPE_WEBHOOK_SECRET` | No | None | Verifies `Stripe-Signature` on `/webhooks/stripe`. Missing makes that endpoint reject every request with `400`, because nothing can be verified without it. It does not stop the application. |
| `STRIPE_PRICE_KEYS_INCLUDED` | No | None | Recurring price for the plan where the operator supplies the API keys. Missing removes that option from the billing page. |
| `STRIPE_PRICE_BYO` | No | None | Recurring price for the plan where the subscriber supplies their own keys. Missing removes that option from the billing page. |
| `STRIPE_PUBLISHABLE_KEY` | No | None | Published alongside checkout. Not secret. |

The application does not create Stripe products, prices, or webhook endpoints.
The configured prices must match the tier and interval encoded by each variable.

## Docker Compose variables

These values are consumed by Compose or PostgreSQL rather than
`config/runtime.exs`.

| Variable | Required | Default | Purpose and missing behaviour |
|---|---|---|---|
| `POSTGRES_USER` | No | `superx` | Creates the PostgreSQL role and forms the app’s `DATABASE_URL`. The database health check uses the same value. Changing it after the `pgdata` volume has been initialized does not rename the existing role. |
| `POSTGRES_PASSWORD` | Compose | None | Password used to initialize PostgreSQL and form `DATABASE_URL`. Compose interpolation stops with `set POSTGRES_PASSWORD in .env` if it is absent or blank. Use a long hexadecimal or otherwise URI-safe value because Compose places it into the URL without escaping. Changing it in `.env` after first initialization does not change the password already stored in PostgreSQL. |
| `POSTGRES_DB` | No | `superx` | Creates the initial database and forms `DATABASE_URL`. Changing it after volume initialization does not create or rename a database automatically. |
| `BIND_ADDR` | No | `127.0.0.1` | Host interface on which Compose publishes port 4000. Keep loopback when nginx runs on the same host. Use `0.0.0.0` only when direct network exposure is intentional and protected elsewhere. |

Compose fixes `PORT=4000` and `SUPERX_UPLOADS_DIR=/app/uploads`; changing those
two in `.env` has no effect unless `docker-compose.yml` is changed.

## Development and test variables

These come from `config/dev.exs` and `config/test.exs`. They are not used by a
production release.

| Variable | Required | Default | Purpose and missing behaviour |
|---|---|---|---|
| `PGUSER` | No | `USER` | PostgreSQL role used by local development and tests over a Unix socket. |
| `USER` | Usually supplied by the shell | None | Fallback database role when `PGUSER` is absent. If neither identifies a usable PostgreSQL role, local database setup fails. |
| `PGSOCKET` | No | `/var/run/postgresql` | PostgreSQL Unix socket directory for development and tests. |
| `MIX_TEST_PARTITION` | No | Empty suffix | Appended to `superx_test` to isolate test databases. For this documentation worktree, use `MIX_TEST_PARTITION=_docs_ref`. |

`SUPERX_VAULT_KEY` is optional outside production. Development and test derive
a deterministic 32-byte key from Phoenix’s configured secret.

## Deployment script variables

These affect `deploy.sh`, not the running application.

| Variable | Required | Default | Purpose and missing behaviour |
|---|---|---|---|
| `HOST` | No | `kit` | SSH and SCP destination understood by the local SSH client. It may be an SSH config alias or hostname. It does not change the script’s hard-coded `https://superx.free/` health check. |
| `DIR` | No | `/var/www/superx.free` | Existing Git checkout and Compose project directory on the remote host. The value is interpolated into the remote shell command; use a simple trusted path without spaces or shell metacharacters. |

For the full deployment workflow, including this script’s assumptions, see
[Deployment](DEPLOYMENT.md#what-deploysh-does). For symptoms caused by wrong or
missing values, see [Troubleshooting](TROUBLESHOOTING.md).

## Related reference

- [Setup](SETUP.md)
- [Deployment](DEPLOYMENT.md)
- [Architecture](ARCHITECTURE.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [FAQ](FAQ.md)
