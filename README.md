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

**Engage** — Mentions and topic feeds sync into one inbox, scored 0-100
for whether they're worth answering and ordered by that rather than by
recency. Replies are drafted in your voice and send immediately, because
a reply two days late isn't a reply.

**Signals** — Standing watches on X: posts matching a search, followers of
an account, people replying to an account, members of a list. Each one
scores whoever it finds against a sentence describing who you're looking
for, and files the keepers in **Contacts**.

**DMs** — Keeps private conversations per connected account, drafts replies
in the account's voice, and reads and sends messages through X with the
user's OAuth grant. See [Direct Messages](#direct-messages) before enabling
it.

**Ask** — Chat with tools over your own data. It can read your analytics,
queue, inbox, contacts, and the library, and draft or queue posts. It
cannot publish; queueing is as far as it goes.

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
  → X API v2          (publishing and private DMs)
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

## Deploying

Production runs on a single box behind nginx. `./deploy.sh` bundles the
current commit, ships it over SSH, rebuilds, and restarts — migrations run
inside the container on boot, so there is no separate step.

```bash
./deploy.sh          # deploy HEAD to superx.free
HOST=other ./deploy.sh
```

First-time setup on a new host: clone the repo, write `.env`, add an nginx
vhost proxying to `127.0.0.1:4000` (with the websocket upgrade on
`/live/websocket`, or LiveView will not connect), issue a certificate, and
enable a systemd unit that runs `docker compose up -d`.

## Configuration

Everything is environment variables; see `.env.example` for the full
list. Only four are required: `DATABASE_URL`, `SECRET_KEY_BASE`,
`SUPERX_VAULT_KEY`, and the X OAuth pair.

Each optional integration degrades rather than breaks:

| Missing | Effect |
|---|---|
| LLM key (`ANTHROPIC_API_KEY` or `DEEPSEEK_API_KEY`) | No drafting, no reply writing, no lead scoring, no Ask. Signals still find people but return them unranked. |
| `TWITTERAPI_IO_KEY` | No corpus, no mentions, no feeds, no Signals. The Create loop still works on posts you write. |
| `SUPERX_ENABLE_DMS` unset or `false` | OAuth keeps its existing scopes and the DMs screen explains how to enable access. |
| `VOYAGE_API_KEY` | Corpus search falls back to full text. |
| `STRIPE_*` | Billing disabled, every account keeps free limits. Correct for a private instance. |

## Which model

Both providers speak Anthropic's Messages API — DeepSeek serves it at
`api.deepseek.com/anthropic` with the same header and content blocks — so
`SUPERX_LLM_PROVIDER` is a base URL and two model names, not a second
client.

| | Writer | Utility |
|---|---|---|
| `anthropic` | `claude-sonnet-5` | `claude-haiku-4-5` |
| `deepseek` | `deepseek-v4-pro` | `deepseek-v4-flash` |

The writer decides whether a post sounds like you, so it gets the better
model. The utility model runs the high-volume classification — engagement
scoring, lead qualification — where cheap is the right call. Override
either with `SUPERX_WRITER_MODEL` / `SUPERX_UTILITY_MODEL`.

Two things about reasoning models, both handled but worth knowing:

- They reject a *named* `tool_choice` while thinking. Structured output
  therefore asks for `any` with exactly one tool defined, which means the
  same thing and is accepted by both providers in both modes.
- They spend the token budget on thinking before writing, so a tight
  `max_tokens` returns a successful response containing no text. That
  surfaces as an error rather than a blank draft. Thinking is turned off
  explicitly on the scoring paths, where it bills as output for no gain.

DeepSeek's `deepseek-reasoner` is not used: it doesn't support function
calling, which Ask's tool loop depends on.

## Reads

Public data SuperX reads from X — the corpus, mentions, feeds, followers,
lists — goes through [twitterapi.io](https://twitterapi.io), a commercial
data API. Writes and private DM reads go through X's own API with your OAuth
token, because those actions and conversations belong behind credentials the
user granted directly.

Two things to know before turning it on:

**It bills per record**, roughly 15 credits per tweet on search. Every
paging helper here takes a mandatory ceiling for that reason — a loop that
pages "until done" can spend a month of budget in a minute.

The nightly corpus refresh is the standing cost. It defaults to 20 topics
at 40 posts each: about 800 posts, near enough 12,000 credits, every
night. Divide your balance by that for your runway in nights, and set
`SUPERX_CORPUS_TOPICS_PER_RUN` and `SUPERX_CORPUS_POSTS_PER_TOPIC` to buy
a library faster or slower. Check what you have actually spent with
`SuperX.ApiCache.spend_report/1` rather than guessing.

Note that on the free tier the binding constraint is speed — one call per
eleven seconds — and on a paid plan it is money. Raising these on a slow
plan buys nothing but a queue.

**Every response is kept.** Reads go through `SuperX.ApiCache`, which
stores each call's raw body keyed by endpoint and parameters, so an
identical call is never bought twice. Rows are never deleted: an expired
one still records that we paid and what came back, which is what makes
`SuperX.ApiCache.spend_report/1` the actual bill.

Answers do expire, per endpoint, because a cache that never did would be
wrong for most of what we read — the corpus search query carries no date,
so the same topic would return the same page forever and the library
would stop growing, and mentions would freeze after the first poll.
Mentions keep for five minutes, searches and follower lists for a day,
profiles for a week. Errors are never cached, or one 500 would last the
whole window.

A run spends up to twelve of those topics on what your users actually
write about and the rest on a rotating built-in list, so a fresh instance
has a library on day one and an established one keeps broadening. Topics
that name a posture rather than a subject — "life", "personal thoughts" —
are skipped: as *queries* they return whatever went viral that day, and
news has no shape worth borrowing. Those accounts lose nothing, because
the writer already falls back to any strong post.

Not everything ingested is offered to the writer. Ranked lists, link
dumps, one-liners, news alerts and posts promising a list they never
deliver are all filtered out — the last because the corpus stores a
thread's opening post and its payload lives in replies that were never
captured. Expect roughly a third of the library to be usable as
templates.

**The free tier is slow.** Advertised at 0.2 QPS and measured tighter;
calls are serialised behind one clock for the whole node and retries back
off at the same interval. Expect roughly one call per 11 seconds until you
subscribe, then lower `TWITTERAPI_IO_MIN_INTERVAL_MS` to match your plan.

A self-hosted Go scraper remains in `scraper/` as an alternative source
behind the same contract, but it carries terms-of-service exposure that
the paid API does not. It is off unless configured, and twitterapi.io wins
when both are present.

## Direct Messages

DM access is deliberately off by default. Before setting
`SUPERX_ENABLE_DMS=true`, change the X app's permission tier in the developer
console from **Read and write** to **Read and write and Direct message**.
SuperX then adds `dm.read` and `dm.write` to new OAuth requests. X requires
both scopes for sending, and every already-connected account must reconnect
after the change.

Do these in order:

1. Upgrade the app permission tier in the X developer console.
2. Set `SUPERX_ENABLE_DMS=true` and restart SuperX.
3. Open **Accounts** and reconnect every account that will use DMs.

Reading and sending both use X's supported OAuth endpoints and the user's
encrypted access token. A maintenance job checks each enabled account every
five minutes, follows X's pagination, and stores the one-to-one message events
X makes available from the previous 30 days. Stored event ids make overlapping
runs idempotent. A 403 during setup means the app permission tier still needs
to be upgraded; an account connected before DM access was enabled is marked for
reconnection without making a DM request.

## Programmatic access

The in-app reference lives at `/api`. Create a token under **Accounts → API
access**. Its secret is shown once; SuperX stores only a readable prefix and a
SHA-256 hash of the remaining secret. Revoking the token takes effect on the
next request.

Send the token as a Bearer credential:

```bash
curl -H 'Authorization: Bearer sx_example.secret' \
  https://your-host/api/queue
```

The API uses the X account currently selected under **Accounts**. Its write
surface ends at the queue: it can create a draft and schedule approved copy,
but it has no endpoint that publishes directly or calls X.

| Endpoint | Response |
|---|---|
| `GET /api/queue` | Scheduled posts by default. Pass `status=draft`, `scheduled`, `publishing`, `posted`, `failed`, or `cancelled` to read another lifecycle state. |
| `GET /api/shelf` | Drafts waiting on Ready to Post, plus the same per-kind counts shown in the app. |
| `GET /api/analytics` | The analytics summary for 30 days. Pass `days=7`, `30`, or `90` to choose a range. |
| `POST /api/posts` | Create a draft. Send `segments` as an ordered list of `{text, media_ids}` objects and optional `tags`. A supplied lifecycle status is ignored. |
| `POST /api/posts/:id/schedule` | Schedule an owned draft into the next open recurring slot. Send `{"at":"2030-08-02T09:30:00Z"}` to choose an unoccupied future time instead. |
| `DELETE /api/posts/:id` | Delete an owned post from SuperX. This does not delete an already-published post from X. |

Successful creation returns `201`; scheduling returns `200`; deletion returns
`204`. Content validation returns `422` with the same field messages as the
composer:

```json
{"errors":{"segments":["post 1 is over 280 characters"]}}
```

Other failures use `{"error":"message"}`. Missing, invalid, and revoked tokens
return `401`; an unknown or unowned post returns `404`; queue conflicts return
`409`; invalid parameters return `422`; and rate limits return `429`.

Rate limits come from the plan definitions and are shared by every token a user
owns: Free 15, Pro 60, Advanced 120, and Ultra 300 requests per minute. Every
authenticated response includes `RateLimit-Limit`, `RateLimit-Remaining`, and
`RateLimit-Reset`; a `429` also includes `Retry-After`. Accounts shows the
current UTC-day request count. Counters are kept on the single application node
and start fresh after a restart.

### CLI and agent skill

The dependency-free Node 20 client is documented in
[`cli/README.md`](cli/README.md). It installs the `superx-free` binary and
covers login, reads, draft creation, scheduling, and local deletion. It has no
direct publish command.

The companion agent instructions live at
[`skills/superx-free/SKILL.md`](skills/superx-free/SKILL.md). The folder follows
the skill layout consumed by `npx skills add` and keeps human approval between
drafting and scheduling.

### MCP clients

The same token exposes SuperX's Ask tools over Streamable HTTP at `/mcp`.
Tools read from the X account currently selected under **Accounts**. They
can draft and queue posts, but they cannot publish to X.

Add a self-hosted SuperX instance to Claude Code with:

```bash
claude mcp add --transport http superx https://your-host/mcp \
  --header "Authorization: Bearer YOUR_API_KEY"
```

Replace `your-host` and `YOUR_API_KEY` with your instance hostname and the
token shown under **Accounts → API access**.

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
