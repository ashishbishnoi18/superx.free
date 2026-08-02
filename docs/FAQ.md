# Frequently asked questions

## What does it cost to run?

The code is MIT licensed and has no licence fee. An operator pays for the
machine, domain, backups, and whichever upstream APIs are enabled.

There is no reliable minimum server price in the repository. The supplied
deployment runs one Phoenix/worker container and PostgreSQL 17 with pgvector
on one host. Database size depends heavily on corpus ingestion because corpus
rows and paid-read cache rows are not routinely purged. Start with a small
general-purpose VM, watch memory, CPU, and volume use, and size from actual
workload. Do not omit off-host backups from the budget.

API charges are usage based and are billed by the providers directly. SuperX’s
own credits are a separate thing entirely; see the next question.

See [Deployment](DEPLOYMENT.md) for the one-box layout and backup set, and
[Configuration](CONFIGURATION.md) for ways to reduce corpus volume.

## What are “AI credits”, and do they cost money?

They are not money and they are not bought. A credit is an internal rate
limit, so one person on a shared instance cannot spend the operator’s LLM
budget in an afternoon. Nothing is charged when one is used, and having
credits left does not mean the provider bill is paid.

Four quotas exist: `credits_month` and `posts_month` roll every 30 days,
`replies_day` and `leads_day` every 24 hours. A credit is claimed *before*
the expensive call, not after, because charging on success lets a user start
unlimited work concurrently before any of it settles. Work that then fails
refunds the credit — though the provider may still bill for tokens it
processed on the way to failing.

**On a single-operator instance they are pure overhead.** Set
`SUPERX_DEFAULT_TIER=ultra` and every limit lifts, which is the right setting
when the person using the software is the person paying its API bills.

## Which keys are actually needed?

The three secrets required to boot production are `DATABASE_URL`,
`SECRET_KEY_BASE`, and `SUPERX_VAULT_KEY`. They are local configuration, not
third-party API keys. Under Compose, `DATABASE_URL` is built from the three
`POSTGRES_*` values.

External credentials are capability based:

| Credential | Needed for | What works without it |
|---|---|---|
| `X_CLIENT_ID` and `X_CLIENT_SECRET` | Production sign-in, account connection, publishing, account analytics, token refresh, and optional DMs | The server boots and shows the X setup state. A new production user cannot sign in. |
| One of `ANTHROPIC_API_KEY` or `DEEPSEEK_API_KEY` | Voice derivation, drafts, reply writing and scoring, lead scoring, Ask, and AI article composition | Manual voice editing, manual post and article writing, queueing, publishing, public-data ingestion, contacts, imported analytics, and stored data continue. |
| `TWITTERAPI_IO_KEY` | Supported public reads: corpus, mentions, feeds, replies, public profiles, followers, lists, and Signals | Official-X writes and private reads continue. The public-data screens stay empty. |
| `VOYAGE_API_KEY` | Semantic corpus retrieval and embedding backfill | PostgreSQL full-text corpus search remains available. |
| `STRIPE_SECRET_KEY`, webhook secret, and selected price IDs | Charging users of a multi-tenant instance | Billing stays disabled and users receive `SUPERX_DEFAULT_TIER`. This is normal for a private instance. |

There is no “one key enables everything” mode. The selected LLM provider does
not fail over to the other provider automatically.

## What do the external services cost?

The figures below were checked on 2 August 2026. They are rough operating
figures, not promises. Providers can change prices and access rules. Follow the
linked provider pages before funding an account.

### X API

The official X API is currently prepaid pay-per-use. Its
[pricing page](https://docs.x.com/x-api/getting-started/pricing) lists, among
other rates, US$0.015 for a content-create request, US$0.20 when that content
contains a URL, US$0.015 for a DM create, US$0.010 per DM event read, and
US$0.010 per user read. X says resources are normally deduplicated within a
UTC day, but describes that as a soft guarantee.

One SuperX thread creates one X post per segment, so its base write cost scales
with segment count. Media uses separate initialize, append, finalize, and
status requests. DM polling and the daily authenticated profile snapshot add
read use. The exact total belongs in the X developer console because endpoint
classification and media charges are upstream policy.

The X OAuth client pair is still required even if only low-volume writes are
used. DM access also requires the app permission tier and a fresh user grant.

### twitterapi.io

twitterapi.io’s [current pricing](https://twitterapi.io/pricing) is US$0.15 per
1,000 returned tweets: 15 provider credits per tweet, with 100,000 credits per
US dollar. Profiles are listed at US$0.18 per 1,000, while followers use
page-size-dependent pricing.

The shipped nightly corpus maximum is 20 topics times 40 posts, or roughly 800
posts. If every query fills, that is about 12,000 credits, US$0.12 per night,
or US$3.60 over 30 nights at that rate. Mentions, feeds, Signals, profiles, and
follower/list reads add to it. Empty or short result sets cost less, and the
persistent cache avoids buying an identical fresh call twice.

The application’s `SuperX.ApiCache.spend_report/1` is useful for finding which
paths are buying records. The provider dashboard remains the billing source of
truth.

### Anthropic

The default writer is `claude-sonnet-5`; the utility model is
`claude-haiku-4-5-20251001`. Anthropic’s
[model documentation](https://platform.claude.com/docs/en/about-claude/models/overview)
lists Sonnet 5 at an introductory US$2 per million input tokens and US$10 per
million output tokens through 31 August 2026, then US$3/US$15. Haiku 4.5 is
US$1/US$5 per million input/output tokens.

Cost per draft varies with voice examples, corpus references, article length,
Ask tool rounds, and reasoning output. The code bounds ordinary generation to
two attempts and Ask to five tool rounds. Failed application operations refund
the user’s SuperX credit, but the upstream provider may still bill tokens it
processed.

### DeepSeek

With `SUPERX_LLM_PROVIDER=deepseek`, the defaults are `deepseek-v4-pro` for
writing and `deepseek-v4-flash` for utility work. DeepSeek’s
[pricing page](https://api-docs.deepseek.com/quick_start/pricing) lists Pro at
US$0.435 per million cache-miss input tokens and US$0.87 per million output
tokens. Flash is listed at US$0.14/US$0.28. Cache-hit input is cheaper.

DeepSeek exposes the Anthropic-compatible endpoint used by this code. SuperX
does not use `deepseek-reasoner`, because Ask requires function calls.

### Voyage

SuperX hard-codes `voyage-3-large` with 1,024 output dimensions. Voyage’s
[pricing page](https://docs.voyageai.com/docs/pricing) lists that older model
at US$0.18 per million tokens with no free-token allowance. It is optional.
Leaving it off saves this bill and selects PostgreSQL full-text search.

### Stripe

Stripe is needed only if this installation sells subscriptions, which a private
instance does not. Stripe charges the operator’s normal payment and billing
fees; see [Stripe pricing](https://stripe.com/pricing) for the operator’s
country. The application adds no surcharge of its own.

## Does it work without an LLM?

Yes, but it is a scheduler and data workspace rather than an AI writing tool.

Without the selected provider key, a user can:

- sign in with X;
- write, edit, schedule, and publish posts manually;
- attach supported images and GIFs;
- manage recurring slots and view publishing failures;
- browse a corpus populated by a read source;
- ingest mentions, feeds, and Signals candidates;
- manage contacts and exports;
- import analytics history and view stored snapshots;
- write and manage long-form articles manually;
- read and send supported DMs manually.

The user cannot automatically derive a voice, generate or remix drafts, draft
replies, score engagements or leads with a model, compose article prose, or use
Ask. Signals still collect candidates, but without model scoring new contacts
are kept at the agent’s configured minimum score. Voice fields remain editable
by hand. Scheduled shelf top-up logs that no LLM is configured and skips work.

## Does it work without twitterapi.io?

The manual create, queue, official-X publishing, authenticated profile
snapshots, and supported DM paths do. Voice derivation can fall back to the
official X endpoint for the connected user’s own recent posts.

The corpus, Engage inbox, and Signals need public data, so all three stay
empty without a twitterapi.io key. An empty corpus makes Inspiration empty and removes
corpus attribution from normal topic drafts; it does not prevent topic-only
drafting. See [Architecture](ARCHITECTURE.md#corpus-and-generation).

## Does data leave the machine?

Yes, when an external integration is enabled. “Self-hosted” means the database
and application run under the operator’s control. It does not mean the product
is offline.

| Destination | Data sent |
|---|---|
| Official X API | OAuth codes and tokens, published text and media, legacy DM text, XChat ciphertext and public keys, account identifiers, and requests for profile, own-post, and DM data. XChat plaintext is encrypted and decrypted locally. |
| twitterapi.io | Public search terms, handles, list/post IDs, cursors, and the API key. It returns public X data that SuperX stores locally. |
| Anthropic or DeepSeek | Prompts can include the user’s profile and voice notes, their own post examples, public corpus posts, article text, reply or DM conversation text, Ask chat history, and tool results drawn from the user’s SuperX data. OAuth tokens are not placed in prompts. |
| Voyage | Corpus post text with author handle, and corpus search query text. |
| Stripe | Price IDs, instance URLs, the SuperX user UUID, team seat count, and an email address when the user has one and no Stripe customer exists yet. |

The browser may also fetch X-hosted avatar URLs returned by an API. Public
analytics summaries and contact circles leave the authenticated UI only when a
user creates and shares their capability URL.

The application ships no product analytics, advertising tracker, or external
telemetry client. Static JavaScript, CSS, fonts, and icons are served locally.
Team invitation email is also not sent by the shipped production configuration:
the mailer remains the local adapter unless an operator changes application
configuration. The invitation link is always available to copy manually.

PostgreSQL contains sensitive material even though X tokens and XChat identity
blobs are encrypted and browser/API token secrets are hashed. Backups should be
treated as sensitive, and the matching `SUPERX_VAULT_KEY` must be protected
separately.

## How does this compare with hosted alternatives?

This repository was built as an open, self-hosted alternative to superx.so. It
is not a hosted clone and does not promise feature or operational parity.

The practical difference is responsibility:

| Self-hosted SuperX | Hosted service |
|---|---|
| Operator controls the code, PostgreSQL data, retention, hostname, and provider accounts. | Vendor normally controls deployment, storage, upgrades, and provider relationships. |
| Operator pays infrastructure and upstream usage directly. | Costs are usually bundled into a subscription and usage policy. |
| Operator performs upgrades, backups, monitoring, abuse prevention, and incident response. | Vendor normally performs operations and offers its own support level. |
| Missing integrations degrade visibly and can be left off. | Hosted products may bundle more integrations but expose less implementation control. |
| No licence fee and no source lock-in. | Less setup work, but data export and customization depend on that service. |

Choose self-hosting for control and auditability, not because running a social
publishing system becomes maintenance-free.

## What does it deliberately not do?

The current boundaries are intentional or explicit limitations in the code:

- It does not auto-approve generated drafts. Generated work lands on Ready to
  Post for review.
- Ask and MCP tools can create Ready to Post drafts but cannot schedule or
  publish. The HTTP API and CLI can schedule an existing, explicitly approved
  draft; the Oban publisher sends that scheduled work later.
- Deleting a local post does not delete an already-published X post.
- Articles publish only after a person marks them ready and chooses Publish in
  the Articles screen. The API, CLI, MCP, and Ask surfaces do not bypass that
  approval step.
- The LiveView upload flow accepts JPEG, PNG, WebP, and GIF files up to 5 MB,
  with four per post segment. It does not accept video; the code explicitly
  avoids pretending to support X’s separate asynchronous video path.
- It does not ingest group DMs. Legacy and encrypted XChat one-to-one threads
  are supported; groups are skipped because the existing conversation model
  has no safe single participant to address when replying.
- It cannot read encrypted messages that predate its first sync. XChat
  distributes a conversation key to the devices registered at the time, and
  this instance registers its own when it first runs. Everything after that
  point decrypts; nothing before it ever will, on any client.
- It cannot publish Articles for an account without X Premium. The endpoint
  returns 403 and the article is left retryable with X’s reason recorded.
- It does not provide full per-post X analytics. Daily totals come from the
  authenticated profile and locally published rows; users can import an X
  analytics CSV for history.
- It does not expose an arbitrary OpenAI-compatible or local LLM endpoint.
  Runtime configuration selects Anthropic or DeepSeek’s Anthropic-format
  endpoint.
- It does not configure production SMTP through environment variables. Team
  invitation links work, but outbound delivery requires a code-level mailer
  adapter configuration.
- It does not synchronize Stripe seat quantity when team membership changes
  mid-cycle. Checkout prices can include seats, but the code comments state
  that automatic changes to a live subscription have not been exercised.
  disabled unless explicitly configured.
- It is optimized for a single application node. DNS node discovery exists,
  but API rate counters are in memory per node and the supplied deployment does
  not configure a multi-node cluster.

For operational failure modes behind these limits, see
[Troubleshooting](TROUBLESHOOTING.md).

## Related reference

- [Setup](SETUP.md)
- [Configuration](CONFIGURATION.md)
- [Deployment](DEPLOYMENT.md)
- [Architecture](ARCHITECTURE.md)
- [Troubleshooting](TROUBLESHOOTING.md)
