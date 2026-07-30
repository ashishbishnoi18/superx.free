# SuperX scraper worker

The read side of SuperX. Populates the corpus of high-performing posts
that the writer draws structural templates from.

Writes — publishing and DMs — never go through here. Those use the
official X API with the user's own OAuth token.

## Why this exists

X's API read quotas make a corpus of any useful size impossible at a
workable price. The corpus is the one part of the product that can't be
built on the official API, so it lives in a separate process that can be
disabled, replaced, or pointed at a different source without touching the
control plane.

## Contract

Line-delimited JSON on stdin/stdout. One request per line in, zero or
more responses per line out, correlated by `id`.

```
→ {"id":"req-1","op":"search","params":{"query":"startups","min_likes":500,"limit":50}}
← {"id":"req-1","type":"item","data":{"x_post_id":"...","text":"...", ...}}
← {"id":"req-1","type":"item","data":{...}}
← {"id":"req-1","type":"done","count":50,"data":{"cursor":"..."}}
```

On startup it emits a handshake before reading anything:

```
← {"type":"ready","data":{"contract":"superx.scraper/v1","ops":["search","profile","ping"],"configured":true}}
```

### Ops

| Op | Params | Purpose |
|---|---|---|
| `ping` | — | Liveness and configuration check |
| `search` | `query`, `min_likes`, `limit`, `lang`, `cursor` | Corpus ingestion |
| `profile` | `handle`, `limit` | Recent posts for one account |

Errors are returned per request and include any count already streamed,
so partial results are still ingested:

```
← {"id":"req-1","type":"error","message":"rate limited by X","count":18}
```

## Build

```bash
cd scraper
go build -o ../priv/scraper .
```

The control plane looks for the binary at `priv/scraper` by default;
override with `config :superx, SuperX.Scraper, binary: "/path/to/scraper"`.

## Configuration

All via environment variables, read at process start.

| Variable | Default | Purpose |
|---|---|---|
| `X_WEB_BEARER` | — | Public web bearer token used to activate a guest session |
| `X_SEARCH_PATH` | — | GraphQL `<queryId>/SearchTimeline` path segment |
| `X_SEARCH_FEATURES` | `{}` | JSON feature-flag blob X requires on the query |
| `X_MIN_REQUEST_INTERVAL` | `2000` | Minimum ms between requests |
| `X_USER_AGENT` | Chrome UA | Sent on every request |
| `HTTPS_PROXY` / `HTTP_PROXY` | — | Route egress through your own infrastructure |

Without `X_WEB_BEARER` and `X_SEARCH_PATH` the worker starts, reports
`configured: false`, and refuses search requests. The rest of SuperX
works normally — Inspiration is simply empty.

`X_SEARCH_PATH` and `X_SEARCH_FEATURES` are configuration rather than
constants because X revises both regularly. When ingestion starts
returning nothing, those two values are what to check first.

## Rate limiting

The worker enforces a minimum interval between requests, with jitter, and
holds one guest token for its lifetime rather than churning them. Requests
are handled serially — X rate-limits per token, so concurrency here would
only produce 429s faster. Scale by running more workers with separate
egress, not by raising concurrency in one.

Please leave the default interval alone unless you have a reason. It is
set to be unremarkable.

## Legal

Scraping X's web endpoints is against X's Terms of Service, whatever the
technical accessibility of the data. That is a decision for whoever
operates this deployment, not one this code makes for you. Consequences
land on the operator: rate limiting, IP blocks, account suspension, or a
letter.

If you would rather not take that on, leave the worker unconfigured. The
corpus can also be populated from any other source — the control plane
only cares about the shape in `protocol.go`, so a licensed dataset, an
export you already own, or a third-party API can be dropped in behind the
same contract.
