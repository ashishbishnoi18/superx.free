# Architecture

SuperX is a Phoenix application designed to run on one host with one
PostgreSQL database. The browser, web server, scheduler, workers, and optional
workers are not separate deployable services.

```text
Browser
  | HTTPS + LiveView WebSocket
nginx
  | HTTP on loopback
Phoenix endpoint
  |-- contexts and LiveViews
  |-- Oban queues and cron
  |-- supervised Go corpus worker
  |-- X, twitterapi.io, LLM, Voyage, and Stripe clients
  |
PostgreSQL
  |-- application rows
  |-- Oban jobs
  |-- full-text and pgvector indexes
  |-- paid-read response cache
  `-- LISTEN/NOTIFY for Oban
```

The intended operational result is one application container and one database
container. There is no Redis, external job queue, separate cron daemon, or
separate worker deployment.

## The supervised process

`SuperX.Application` starts these important children under one OTP supervisor:

- `SuperX.Repo` owns PostgreSQL connections.
- `DNSCluster` optionally discovers other BEAM nodes through
  `DNS_CLUSTER_QUERY`.
- `Phoenix.PubSub` carries application UI notifications.
- `SuperX.TaskSupervisor` moves LLM calls out of LiveView processes so a slow
  provider does not block the UI process.
- `SuperXWeb.ApiRateLimit` keeps programmatic API counters for the current
  node.
- `SuperX.TwitterAPI` serializes paid public reads behind one node-wide clock.
- Oban executes durable jobs and cron schedules.
- `SuperXWeb.Endpoint` serves HTTP, WebSockets, and long polling.

The supervisor uses `:one_for_one`: a failed optional worker can restart
its binary or credentials are missing. In that state it reports itself
unconfigured and corpus work skips it.

## Why PostgreSQL does most of the work

PostgreSQL is already required for durable product data. Reusing it reduces
the number of moving parts an operator must back up and keep alive.

### Database

Ecto schemas store users, encrypted X tokens and XChat identities, browser
sessions, API tokens, voice profiles, drafts, scheduled posts, analytics
snapshots, engagement inboxes, contacts, DMs, subscriptions, quotas, and the
corpus. Migrations also enable:

- `citext` for case-insensitive emails and handles;
- `pg_trgm` for fuzzy handle and keyword matching;
- `vector` for pgvector embeddings.

The supplied Compose image is `pgvector/pgvector:pg17`, so the `vector`
extension needed by the first migration is available.

### Queue and scheduler

Oban persists jobs in PostgreSQL. Jobs survive application restarts, are
claimed transactionally, and can be retried without a separate broker. The
configured queues keep latency-sensitive publishing apart from bulk work:

| Queue | Concurrency | Work |
|---|---:|---|
| `publishing` | 20 | Sending posts, threads, and media to X |
| `generation` | 10 | Drafting, voice work, reply generation, and content batches |
| `ingestion` | 10 | Corpus reads, mention feeds, embeddings, and Signals |
| `maintenance` | 5 | Dispatch, token refresh, DMs, analytics, and quotas |

Oban Cron inserts recurring jobs. With the shipped configuration, it:

- dispatches due scheduled posts every minute;
- refreshes expiring X tokens every 15 minutes;
- records analytics daily at 00:10;
- starts the corpus refresh daily at 01:00;
- tops up shelves daily at 02:30;
- checks user-configured content workers every minute;
- syncs mentions and topic feeds every 20 minutes;
- syncs DMs every five minutes;
- refreshes per-post metrics (likes, views) every 30 minutes;
- runs due per-post automations (repost, plug, delete) every 15 minutes;
- runs due Signals watches every two hours at minute 15;
- rolls quota windows daily at midnight.

Cron uses the scheduler’s default UTC timezone. User publishing slots are a
different concern: they are stored in the user’s local timezone and resolved
with a real timezone database so daylight-saving transitions remain correct.

Completed Oban jobs are retained for seven days. The Lifeline plugin rescues
jobs left executing for more than 30 minutes after a node dies.

### Vector and full-text store

Corpus posts contain a PostgreSQL-generated English `tsvector` column with a
GIN index. This is the always-available retrieval path.

When `VOYAGE_API_KEY` is present, ingestion also stores 1,024-dimensional
`voyage-3-large` vectors in the same rows. An HNSW index supports cosine
distance. Search first retrieves semantically near posts, then re-ranks them
by measured engagement. If Voyage is absent or embedding a query fails, the
same operation falls back to PostgreSQL full-text search.

Keeping both paths in one table avoids an external vector database and keeps
backup and tenancy rules identical to the rest of the application.

### Pub/sub, precisely

PostgreSQL is Oban’s cross-process pub/sub transport. With no notifier override,
Oban uses PostgreSQL `LISTEN/NOTIFY` to wake queues and coordinate jobs.

LiveView-facing events use `Phoenix.PubSub`, whose configured default adapter
is distributed Erlang PG2, not PostgreSQL. For example, a shelf worker
broadcasts `:shelf_updated` so an open Ready to Post screen refreshes. This is
ephemeral notification; the shelf row itself is durable in PostgreSQL. On the
supplied single-node Compose deployment the distinction has little operational
effect, but it matters if the app is scaled to multiple nodes: BEAM
distribution and node discovery must work for Phoenix PubSub, while Oban
continues to coordinate through PostgreSQL.

## Domain boundaries

Phoenix contexts hold the business rules rather than LiveViews or workers.
The main boundaries are:

- `SuperX.Accounts`: users, sessions, connected X accounts, OAuth handshakes,
  API credentials, and account selection.
- `SuperX.Content`: voice profiles, drafts, generated shelf items, recurring
  slots, publishing state, and the corpus.
- `SuperX.Engage`: mentions, feeds, reply drafts, and engagement status.
- `SuperX.Signals`: standing public-data watches, leads, contact lists, shares,
  and exports.
- `SuperX.DMs`: private, account-scoped conversations and messages.
- `SuperX.Analytics`: daily snapshots, imports, trends, and public capability
  links.
- `SuperX.Billing`: static plans, subscriptions, rolling quotas, and an
  append-only AI credit ledger.
- `SuperX.Articles`: long-form drafts, review state, and X publication outcomes.
- `SuperX.Ask`: an LLM tool loop over the same contexts.

Oban workers are thin orchestration layers around those contexts. LiveViews
load and mutate through them rather than owning persistence logic.

## The X API split

SuperX deliberately has two main X-facing clients because the data has
different authorization and cost properties.

### Public reads: twitterapi.io

`SuperX.TwitterAPI` reads public data through twitterapi.io:

- high-performing posts for the shared corpus;
- recent public posts for voice derivation and selected inspiration creators;
- mentions and topic feeds;
- replies, follower lists, list timelines, and profiles used by Signals.

These calls need no user OAuth token. They are globally paced by one GenServer
because the provider rate applies to the application node, and every paging
operation has an explicit result ceiling because billing is per returned
record.

The optional Go worker is only a corpus fallback. Corpus ingestion prefers
twitterapi.io when both are configured. The worker cannot fill Engage or
Signals. It uses X’s public web GraphQL surface and carries the operational and

### Writes and private reads: X API v2

`SuperX.X` uses the official X API with a user’s OAuth grant for:

- OAuth exchange, refresh, and revocation;
- reading the authenticated profile;
- publishing posts, replies, threads, Articles, images, and GIFs;
- reading and sending legacy and encrypted XChat DMs;
- reading the user’s own recent posts as a voice-derivation fallback when
  twitterapi.io is unavailable.

Writes must be attributable to the user’s grant. DMs cannot be read from a
public-data provider at all. These narrower, lower-volume operations therefore
stay behind X OAuth even though bulk public reads use another provider.

X access and refresh tokens and opaque XChat private-key blobs are encrypted in
PostgreSQL with AES-256-GCM. `SUPERX_VAULT_KEY` is the key boundary. XChat
encryption, signature verification, and decryption run in the official Chat
XDK through a local Node Port; OAuth tokens remain in the Elixir HTTP client.
Token refresh is serialized per account with a PostgreSQL advisory lock because
X rotates refresh tokens: two concurrent refreshes could otherwise store the
already-invalidated loser.

## The paid read cache

`SuperX.ApiCache` sits in front of every twitterapi.io GET. The cache key is the
provider, endpoint path, and a SHA-256 hash of canonicalized parameters. Each
page cursor is therefore a different cached request.

Current freshness windows are:

| Read | Fresh for |
|---|---:|
| Mentions | 5 minutes |
| Replies and list timelines | 1 hour |
| A user’s recent posts | 6 hours |
| Search and follower lists | 24 hours |
| User profiles | 7 days |
| Other endpoints | 1 hour |

Cache hits do not acquire the upstream rate limiter. Successful misses are
stored with the response body, parameters, returned-record count, hit count,
and timestamps. Upstream errors are never cached, so one transient 500 or 429
does not become a cache-window outage. Cache write failure is also best effort:
the caller keeps the response it already received.

### Why answers expire but rows do not

An answer cannot remain fresh forever. A topic search without a moving date
would return the same page forever and stop corpus growth. Permanent mention
caching would freeze the inbox after its first poll. Each endpoint therefore
uses a freshness window based on how quickly that data matters.

Expiry affects serving, not storage. Once a row is older than its endpoint
TTL, it is a miss and the upstream is called again. The unique cache row for
that provider/path/parameter key is then updated in place rather than deleted.
Keeping rows provides paid-read bookkeeping and hit counts for
`SuperX.ApiCache.spend_report/1`; it also prevents a cleanup job from erasing
the evidence needed to diagnose repeated buys. The trade-off is database
growth across distinct request keys, which operators must monitor and back up.

## Corpus and generation

The corpus is global rather than per user. A post bought once can provide a
structural reference for every account, amortizing ingestion cost.

The nightly refresh selects up to 12 specific topics learned from active voice
profiles and fills the remainder of its topic budget from a rotating built-in
seed list. Vague posture words such as “life” are not used as searches because
they return the day’s news rather than reusable writing structures. Ingestion
is one Oban job per topic, so one bad query does not stall the rest.

Corpus rows are upserted by X post ID. Engagement is weighted and normalized
against author reach so large accounts do not automatically dominate. Full
text and optional vectors find candidates; the final selection favors posts
that actually performed. Lists, link dumps, very short posts, news alerts, and
thread openings whose promised payload lives in missing replies are excluded
from generation candidates.

The writer borrows structure, not text. It checks generated drafts against
corpus and creator references for copied phrases. A derivative first attempt
is discarded and retried without reference material. A failed generation
refunds the application credit claimed before the provider call.

An empty corpus does not stop topic-based drafting. The writer uses a
topic-only prompt and stores a generation with no corpus attribution. The
Inspiration screen stays empty, and a worker configured specifically for
“Niche trends” cannot run because that mode requires a corpus source. See
[Troubleshooting](TROUBLESHOOTING.md#the-inspiration-library-is-empty-or-drafts-have-no-source).

Generated work lands on the Ready to Post shelf. Nothing generated is
automatically approved. A user accepts or edits it before it enters a
publishing slot.

## Publishing correctness

The queue dispatcher wakes every minute and inserts a `PublishPost` job for
each due row. The publisher conditionally changes a post from `scheduled` to
`publishing`; if another dispatcher already claimed it, the second job exits.
This prevents duplicate publication without a distributed lock service.

Attachments stay as durable local file keys until the publishing job runs. X
media IDs are short-lived, so uploading to X at draft time would let IDs expire
before a future slot. The publisher uploads media immediately before the post.

X rate limits return the post to `scheduled` and snooze the job until the reset
window, capped at 15 minutes. Ordinary transient failures retry up to five
attempts. A permanent 4xx becomes visible immediately.

A partially published thread is not retried. The code records the X IDs that
did publish, marks the thread failed, and asks the user to finish it manually.
Retrying the whole operation would duplicate the already-live prefix.

The HTTP API and MCP surface stop at creating drafts and queueing approved
work. Neither has a direct-publish operation. This preserves the same review
boundary used by the UI.

## Failure as a configured state

Optional providers expose `configured?` checks and return explicit errors such
as `:not_configured`, `:out_of_credits`, or `:embeddings_not_configured`.
Scheduled workers normally log and skip unavailable optional work rather than
crashing the release:

- no LLM skips shelf generation and leaves manual workflows available;
- no twitterapi.io key leaves public-data screens empty;
- no Voyage key selects full-text retrieval;
- no Stripe configuration leaves the instance on its default tier;
- DM access off makes no DM requests;

The exceptions are core production secrets and the database connection. A
production release cannot safely run without `DATABASE_URL`,
`SECRET_KEY_BASE`, or `SUPERX_VAULT_KEY`, so those fail during startup.

See [Configuration](CONFIGURATION.md) for the exact variable table,
[Deployment](DEPLOYMENT.md) for the production topology, and
[Troubleshooting](TROUBLESHOOTING.md) for symptom-first recovery steps.

## Related reference

- [Setup](SETUP.md)
- [Configuration](CONFIGURATION.md)
- [Deployment](DEPLOYMENT.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [FAQ](FAQ.md)
