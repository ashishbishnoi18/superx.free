# SuperX

**An open-source, self-hosted growth workstation for X (Twitter).**
It learns how you write, finds posts worth learning from, drafts in your
voice, and publishes on a schedule you set.

A free alternative to hosted tools like [superx.so](https://superx.so),
[Hypefury](https://hypefury.com) and [Typefully](https://typefully.com) —
except it runs on your own machine, with your own API keys, and nothing
leaves the box.

```
git clone <your-fork> superx && cd superx
cp .env.example .env      # add your keys — see docs/SETUP.md
docker compose up -d --build
```

Then open `http://localhost:4000` and sign in with X.

- **Setup, step by step** → [docs/SETUP.md](docs/SETUP.md)
- **Every environment variable** → [docs/CONFIGURATION.md](docs/CONFIGURATION.md)
- **Running it in production** → [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)
- **How it works and why** → [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- **When something breaks** → [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- **Costs and common questions** → [docs/FAQ.md](docs/FAQ.md)

---

## Why this exists

Posting consistently on X is mostly a scheduling and memory problem, and
the tools that solve it charge $49–199 a month to hold your OAuth token,
your drafts, and your audience data on their servers.

Everything here runs on one box you control. There is no telemetry, no
analytics pixel, no account to create, and no vendor who can change the
price or read your drafts. You bring your own API keys — the same ones the
hosted tools use on your behalf — and pay the underlying providers
directly, which is a few dollars a month rather than a few hundred.

## What it does

**Create** — Derives a voice profile from your own posts, retrieves a
high-performing post from a shared corpus, and rewrites its *structure*
onto one of your topics in your voice. Drafts land on an approval shelf;
nothing publishes without you accepting it.

**Queue** — Recurring weekly slots in your local time. Approved drafts fill
the next opening and publish automatically, with retries, DST-correct
scheduling, and a visible failure state when X refuses.

**Workers** — Named, configurable generators. Pick a voice, a topic source
and a batch size; run on demand or on a schedule. Output goes to the same
approval shelf.

**Engage** — Mentions and topic feeds in one inbox. Mentions are scored
0–100 for whether they are worth answering and ordered by that; feeds read
newest first. Replies are drafted in your voice and send immediately,
because a reply two days late is not a reply.

**Signals** — Standing watches on X: posts matching a search, followers of
an account, people replying to an account, people posting in a list. Each
scores whoever it finds against a sentence describing who you are looking
for, and files the keepers in **Contacts**.

**Contacts** — Lists, CSV export, and a revocable public link if you want
to share one.

**Inspiration** — Search the corpus of high-performing posts. Full-text
always, vector similarity when embeddings are configured, plus filters on
engagement, length and date. **Outlier detection** scores how far a post
beat the median for its author's follower band, so a 3× post from a small
account outranks a bigger post that merely had reach.

**Analytics** — Nightly snapshots, follower trend, posting streak, and an
estimate of which posts drew followers. Import your X analytics export to
backfill history.

**Ask** — Chat with tools over your own data: analytics, queue, shelf,
inbox, contacts, feeds, articles and the library. It can draft and queue.
It cannot publish.

**Articles** — Long-form composition with AI assistance.

**API, MCP and CLI** — A read-write HTTP API, an [MCP](https://modelcontextprotocol.io)
server so Claude Code, Codex or ChatGPT can drive your account directly,
and a zero-dependency CLI.

## What it deliberately does not do

Honest limitations, because you will find them anyway:

- **It never publishes without your approval.** There is no autopilot, and
  the API and MCP surfaces stop at queueing on purpose.
- **The DM inbox will look empty.** X's API only exposes legacy,
  unencrypted conversations. Anything in XChat is invisible to it —
  verified against the live API, not assumed. Sending works.
- **Articles do not publish to X.** X's API has no long-form endpoint at
  all; the create-post body has no field for one.
- **The corpus starts empty** and fills at ~800 posts a night. A hosted
  competitor hands you millions on day one; you build yours.
- **No bulk DM outreach.** Sending automated DMs to strangers is the one
  feature here that would mostly be used for spam.

## Stack

```
browser
  → Phoenix LiveView
  → Postgres          (data, job queue, vector store, pub/sub)
  → Oban              (scheduling, publishing, ingestion, generation)
  → twitterapi.io     (public reads: corpus, mentions, feeds, watches)
  → X API v2          (writes, and private DM reads, with your OAuth token)
```

No Redis, no separate queue service, no separate scheduler, no external
cache. Postgres is all of them. Web, workers, cron and scraper run as one
supervised OS process on one box.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for why the read and write
paths use different providers.

## What you need

Three keys, all obtainable in a few minutes. Full walkthrough in
[docs/SETUP.md](docs/SETUP.md).

| | For | Cost |
|---|---|---|
| **X developer app** | Sign-in and publishing | Pay per use — about $0.015 a post, no free tier |
| **twitterapi.io** | The corpus, mentions, feeds, Signals | ~$0.15 per 1,000 posts read |
| **An LLM key** | Drafting, replies, scoring | DeepSeek or Anthropic; a few dollars a month |

Each is optional and degrades rather than breaks. No LLM key means no
drafting, but the queue and scheduling still work. No twitterapi.io key
means no corpus or feeds, but you can still write and publish.

Running cost for one person is typically **$5–15 a month** paid directly to
those providers. See [docs/FAQ.md](docs/FAQ.md) for the arithmetic.

## Local development

Needs Elixir 1.19, Postgres 17+ with pgvector, and Go 1.25.

```bash
mix setup
cd scraper && go build -o ../priv/scraper . && cd ..
mix superx.dev.seed     # demo user, corpus, shelf, analytics
mix phx.server
```

The seed prints a sign-in URL, so you can exercise every screen without X
or LLM credentials.

```bash
mix test          # 357 tests
mix precommit     # format, compile with warnings as errors, test
```

## Contributing

Issues and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for how the codebase is written — in
particular, comments here explain *why* rather than what, and tests
concentrate on the paths that spend money or lose data.

Security issues: please read [SECURITY.md](SECURITY.md) rather than opening
a public issue.

## Licence

MIT. See [LICENSE](LICENSE).
