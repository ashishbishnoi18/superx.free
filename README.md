# SuperX

A self-hosted X (Twitter) growth workstation. It learns how you write,
finds posts worth learning from, drafts in your voice, and publishes on a
schedule you set.

Built as an open alternative to [superx.so](https://superx.so). Runs on
one box. No third-party analytics, no telemetry, no vendor lock-in.

## What it does

**Create** — Derives a voice profile from your own posts, retrieves a
high-performing post from a shared corpus, and rewrites its *structure*
onto one of your topics in your voice. Drafts land on an approval shelf;
nothing publishes without you accepting it.

**Queue** — You define recurring weekly slots in your local time.
Approved drafts fill the next open one and publish automatically, with
retries and a visible failure state when X refuses.

**Inspiration** — Hybrid search over the corpus: Postgres full text
always, vector similarity when embeddings are configured, re-ranked by
engagement normalised against author reach.

**Analytics** — Nightly per-account snapshots, headline metrics, follower
trend, and a posting-streak heatmap.

## Stack

```
browser
  → Phoenix LiveView
  → Postgres          (data, job queue, vector store, pub/sub)
  → Oban              (scheduling, publishing, ingestion, generation)
  → Go worker         (corpus reads, over a Port)
  → X API v2          (publishing — writes only)
```

Deliberately no Redis, no separate queue service, no separate scheduler,
and no external cache. Postgres is all of them. The whole app — web,
workers, cron, and the scraper — runs as one supervised OS process.

## Running it

Requires Docker and a domain pointed at your box.

```bash
git clone <your-fork> superx && cd superx
cp .env.example .env
```

Generate the two secrets and put them in `.env`:

```bash
docker run --rm hexpm/elixir:1.19.5-erlang-26.2.5.20-debian-trixie-20260610-slim \
  sh -c 'mix local.hex --force >/dev/null && mix phx.gen.secret'   # SECRET_KEY_BASE
openssl rand -base64 32                                            # SUPERX_VAULT_KEY
```

Create an X app at [developer.x.com](https://developer.x.com): OAuth 2.0
with PKCE, type **Web App**, callback `https://your-host/auth/x/callback`.
Put the client id and secret in `.env`.

Then:

```bash
docker compose up -d --build
docker compose exec app /app/bin/migrate
```

Open your host and sign in with X.

`SUPERX_VAULT_KEY` encrypts stored OAuth tokens. Back it up. If you lose
it, every user has to reconnect their account.

### Local development

Needs Elixir 1.19, Postgres 17+ with pgvector, and Go 1.25.

```bash
mix setup
cd scraper && go build -o ../priv/scraper . && cd ..
mix superx.dev.seed     # demo user, corpus, shelf, analytics
mix phx.server
```

The seed prints a sign-in URL, so you can exercise every screen without X
or LLM credentials.

## Configuration

Everything is environment variables; see `.env.example` for the full
list. Only four are required: `DATABASE_URL`, `SECRET_KEY_BASE`,
`SUPERX_VAULT_KEY`, and the X OAuth pair.

Each optional integration degrades rather than breaks:

| Missing | Effect |
|---|---|
| `ANTHROPIC_API_KEY` | No voice derivation or drafting. Everything else works; you write posts yourself. |
| `VOYAGE_API_KEY` | Corpus search falls back to full text. |
| `STRIPE_*` | Billing disabled, every account keeps free limits. Correct for a private instance. |
| `X_WEB_BEARER` / `X_SEARCH_PATH` | Corpus stays empty, Inspiration shows a setup note. |

## The corpus

`Inspiration` and the "inspired by a post with N likes" attribution both
read from a shared library of high-performing posts. Populating it is the
one part of this that X's API can't do at a workable price, so it lives
in a separate Go worker you opt into — see
[`scraper/README.md`](scraper/README.md), including the terms-of-service
position, before enabling it.

The control plane only cares about the shape in `scraper/protocol.go`, so
a licensed dataset or a third-party API can be dropped in behind the same
contract.

## Operating notes

**Scheduled publishing** ticks every minute. A post is claimed with a
conditional status update, so two dispatcher runs can't publish it twice.

**Partial threads** are not retried. If a thread fails after posting
three of five segments, the published ids are recorded and it stops —
retrying would duplicate the first three. The Failed tab shows how far it
got so you can finish by hand.

**Rate limits** reschedule with X's reset window rather than counting as a
failed attempt.

**Token refresh** runs every 15 minutes and is serialised per account. X
rotates refresh tokens on use, so concurrent refreshes would race and
persist a token X has already revoked.

**Credits** are claimed before the model call and refunded if it fails, so
a provider outage never costs a user anything. The claim is a single
conditional `UPDATE`, so concurrent requests can't oversell the limit —
there's a test that asserts exactly this.

## Tests

```bash
mix test
```

Covers token encryption, quota concurrency, slot scheduling across time
zones and DST, post validation, publish claiming, and Stripe webhook
signature verification including replay rejection.

## Licence

MIT.
