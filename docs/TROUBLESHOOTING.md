# Troubleshooting

Start with container state and recent logs:

```bash
cd /var/www/superx.free
docker compose ps
docker compose logs --tail=200 app
docker compose logs --tail=100 db
```

Validate `.env` interpolation separately:

```bash
docker compose config >/dev/null
```

Do not paste the unredacted output of `docker compose config` into an issue. It
contains secrets. [Configuration](CONFIGURATION.md) lists the expected values
and their exact missing behaviour.

## X sign-in is not configured

**Symptom:** The home page marks X as not configured, or pressing **Sign in
with X** returns to `/` with “X sign-in is not configured on this server.”

The application enables OAuth only when both `X_CLIENT_ID` and
`X_CLIENT_SECRET` are non-blank. Missing X credentials do not crash the server;
they deliberately leave it in this setup state.

Check the boolean without printing either secret:

```bash
docker compose exec app /app/bin/superx rpc \
  'IO.inspect(SuperX.X.configured?(), label: "x_configured")'
```

Set both variables in `.env`, set the public host and callback, then recreate
the app container:

```dotenv
PHX_HOST=superx.example.com
X_CLIENT_ID=...
X_CLIENT_SECRET=...
X_REDIRECT_URI=https://superx.example.com/auth/x/callback
```

```bash
docker compose up -d --force-recreate app
```

Register exactly the same callback in the X developer console. The app uses
OAuth 2.0 Authorization Code with PKCE and expects a Web App client.

## X redirects back, but sign-in still fails

**Symptom:** X authorization appears to succeed, then SuperX says “We couldn't
complete sign-in with X.” A cancelled or old link may instead say the link
expired.

Inspect the app log for `X OAuth callback failed`. Common causes are:

- `X_REDIRECT_URI` differs from the registered callback by scheme, host, port,
  path, or trailing slash;
- nginx does not send `Host` and `X-Forwarded-Proto` correctly;
- the callback sat for more than ten minutes or was already consumed;
- the client ID and secret belong to different X apps;
- X refused one of the requested scopes.

OAuth request rows are single-use and expire after ten minutes. Start a new
sign-in rather than reloading an old callback URL.

For a public deployment, make sure `.env` does not retain the example value
`http://localhost:4000/auth/x/callback`.

## Text posts work, but posts with images fail with 403

**Symptom:** Plain text publishes. The first post with an image or GIF moves to
Failed and reports an X 403. Logs show a failure under `/media/upload/...`.

`tweet.write` does not grant media upload. X requires the separate
`media.write` OAuth scope. SuperX includes `media.write` in every new OAuth
request, but an account connected under an older grant does not acquire new
scopes automatically.

1. Confirm the X developer app permits media upload and the expected read and
   write permissions.
2. Open **Accounts** and reconnect the affected X account.
3. During X authorization, make sure the new grant includes media access.
4. Retry by creating or rescheduling a post after reconnection.

Do not repeatedly retry the same rejected job before fixing the grant. A 4xx
other than timeout or rate limiting is treated as permanent and shown to the
user immediately.

If the error says an attached file is missing rather than 403, restore the
`uploads` volume; that is a different failure.

## DMs say access is off or the account must reconnect

**Symptom:** The DMs page says the installation has disabled access, or says
the selected account has not granted DM access.

DM setup has three ordered parts:

1. Change the X developer app permission tier to **Read and write and Direct
   message**.
2. Set `SUPERX_ENABLE_DMS=true` and recreate the app container.
3. Reconnect every existing account so its new OAuth grant includes both
   `dm.read` and `dm.write`.

Enabling the flag first can make X reject the entire OAuth request because the
app is asking for scopes its permission tier does not allow. Existing token
scope arrays are checked before any DM API call; accounts without both scopes
are marked for reconnection.

A 403 during scheduled DM sync means the X app permission tier is still not
correct. A 403 while sending to one recipient can also mean that recipient
does not accept DMs from the account.

## The DM inbox stays empty although setup is correct

**Symptom:** The DMs page says incoming sync is configured, the five-minute
job runs without an error, but conversations visible in X do not appear.

This is usually an upstream limitation, not a local sync bug. The official X
DM API used by SuperX sees legacy, unencrypted conversations. XChat, the
encrypted inbox served by X at `/i/chat`, is invisible to the polling
endpoints. In this case `/2/dm_events` can correctly return no events even
while the conversation is open in X.

The distinction can be tested without exposing message text: send a message
through the API-backed SuperX thread. Messages created through the API and
legacy threads can be read back; XChat messages may remain absent. SuperX
stores the event IDs it can see and deduplicates overlapping polls. It reads
the previous 30 days.

There is no configuration fix for XChat. Supporting it would require the X
Account Activity chat webhook surface, which this repository does not
implement. Sending and legacy conversation sync can still work.

## The read API is out of credits

**Symptom:** Engage says “The read API is out of credits.” Signals records
`twitterapi.io is out of credits`, corpus ingestion stops, or logs contain
`twitterapi.io is out of credits` after an HTTP 402.

The client maps upstream 402 responses to `:out_of_credits`. Corpus ingestion
does not retry that condition because retrying cannot change the balance.
Mention and Signals jobs also stop their current work.

1. Check the twitterapi.io balance for the key in `TWITTERAPI_IO_KEY`.
2. Top up the existing account, or replace the key in `.env` and recreate the
   app container.
3. Review the nightly budget. The default 20 topics times 40 posts can request
   about 800 posts per night.
4. Lower `SUPERX_CORPUS_TOPICS_PER_RUN` or
   `SUPERX_CORPUS_POSTS_PER_TOPIC` if the standing corpus spend is too high.
5. Trigger the failed action again or wait for its next scheduled run.

Errors are never cached, so a 402 does not remain after the upstream account
is funded. Successful prior responses remain available until their endpoint
TTL expires.

Inspect what the application’s persistent cache currently records for the
last 30 days:

```bash
docker compose exec app /app/bin/superx rpc \
  'IO.inspect(SuperX.ApiCache.spend_report(), pretty: true)'
```

This report is application bookkeeping, not the provider’s authoritative
invoice. Compare it with the upstream dashboard.

## Public reads are rate limited with 429

**Symptom:** Logs or Signals report rate limiting, reads arrive slowly, or the
upstream intermittently returns 429 while a balance remains.

`TWITTERAPI_IO_MIN_INTERVAL_MS` is one node-wide minimum interval. A cache miss
waits behind the same clock as every other paid read. Req retries transient
responses up to three times and spaces those retries at increasing multiples
of the interval.

Under Compose the default is 6,000 ms. Raising it reduces request rate.
Lowering it only helps when the upstream plan allows the corresponding rate;
otherwise it produces more 429 responses. The Go scraper has a separate
`X_MIN_REQUEST_INTERVAL` and is not a way to accelerate twitterapi.io.

## The Inspiration library is empty or drafts have no source

**Symptom:** Inspiration says “The library is empty.” Generated drafts have no
“Inspired by” attribution. A content worker using **Niche trends** says no
drafts were written because the inspiration library is empty.

The corpus needs at least one configured read source:

- `TWITTERAPI_IO_KEY`, which is preferred; or
- both `X_WEB_BEARER` and a current `X_SEARCH_PATH` for the optional Go
  worker.

Without either source, the nightly refresh logs `Skipping corpus refresh: no
read source configured`. twitterapi.io is the supported path for all public
read features. The Go worker only substitutes for corpus ingestion and has the
terms-of-service limitation documented in `scraper/README.md`.

Check the stored row count:

```bash
docker compose exec app /app/bin/superx rpc \
  'IO.inspect(SuperX.Content.Corpus.count(), label: "corpus_posts")'
```

After configuring a source, wait for the 01:00 UTC cron run or enqueue a
refresh now:

```bash
docker compose exec app /app/bin/superx rpc \
  'IO.inspect(Oban.insert(SuperX.Workers.CorpusRefresh.new(%{})))'
docker compose logs -f app
```

The refresh inserts one ingestion job per topic, and provider pacing may make
the first fill gradual.

An empty corpus does not make every draft fail. The normal writer falls back
to a topic-only prompt, so the stored draft has no corpus source or
attribution. The Niche trends worker is stricter because its topic is supposed
to come from a recent corpus post; it returns `:no_corpus_posts` instead of
pretending a trend exists.

If the Go worker is configured but searches suddenly return nothing, check
`X_SEARCH_PATH` and `X_SEARCH_FEATURES`. X changes that private GraphQL shape.

## Drafting controls are missing or generation never runs

**Symptom:** Voice shows only manual fields, Ask has no chat form, the shelf
does not top up overnight, and drafting buttons are absent or fail.

The selected LLM provider has no usable key. Check the provider without
printing a key:

```bash
docker compose exec app /app/bin/superx rpc \
  'IO.inspect({SuperX.AI.provider(), SuperX.AI.configured?()}, label: "ai")'
```

For the default provider set `ANTHROPIC_API_KEY`. For DeepSeek, set both
`SUPERX_LLM_PROVIDER=deepseek` and `DEEPSEEK_API_KEY`. The application does not
fall back from one provider to the other when the selected call fails.

If configured calls return model-not-found errors, check
`SUPERX_WRITER_MODEL` and `SUPERX_UTILITY_MODEL`. Blank overrides are treated
as absent and use the defaults in [Configuration](CONFIGURATION.md).

Provider failures refund the application credit claimed for the operation.
They do not restore upstream tokens already billed by the provider.

## The page loads but LiveView says disconnected

**Symptom:** Initial HTML and CSS render, then the top bar remains active,
forms do nothing, or the browser repeatedly reconnects. The network panel
shows `/live/websocket` failing instead of status `101 Switching Protocols`.

nginx must proxy the WebSocket upgrade explicitly:

```nginx
location /live/websocket {
    proxy_pass http://127.0.0.1:4000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 3600s;
    proxy_buffering off;
}
```

Inspect the effective nginx configuration, not only the file you intended it
to load:

```bash
sudo nginx -T
sudo nginx -t
```

Also check:

- `BIND_ADDR=127.0.0.1` and the app container publishes `127.0.0.1:4000`;
- nginx can connect to that address;
- the certificate covers `PHX_HOST`;
- a CDN or second proxy also allows WebSockets;
- `Host` and `X-Forwarded-Proto` reach Phoenix unchanged;
- the websocket location is in the HTTPS vhost certbot actually enabled.

See the complete vhost in [Deployment](DEPLOYMENT.md#3-configure-nginx-including-liveview).

## HTTP redirects forever behind the proxy

**Symptom:** The browser reports too many redirects after TLS is enabled.

Production forces HTTPS. nginx terminates TLS, so Phoenix must receive
`X-Forwarded-Proto: https` on the proxied request. Set:

```nginx
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Proto $scheme;
```

Check that a CDN in front of nginx also passes the original scheme. Confirm
`PHX_HOST` is the public hostname, not the container name or `localhost`.

## The app cannot become healthy on the first boot

**Symptom:** The app container restarts. Logs mention a missing `oban_jobs`
table, another undefined table, or migrations. `docker compose exec app ...`
cannot run because the container never stays up.

The supplied `/app/bin/start` solves the first-boot ordering problem by running
`/app/bin/migrate` before it starts the full application. Oban queries its
tables immediately, so starting Phoenix first and planning to migrate with
`docker compose exec` cannot work on an empty database.

Check that the service still uses the image’s default command and that a fork
has not replaced `/app/bin/start`. Run migration in a one-off container:

```bash
docker compose run --rm app /app/bin/migrate
docker compose up -d app
docker compose logs --tail=200 app
```

If migration reports that the `vector` extension is unavailable, the database
server is not the supplied `pgvector/pgvector:pg17` image and does not have
pgvector installed. The first migration also enables `pg_trgm` and `citext`.
Install those extensions or use the supplied image before retrying.

If migration reports authentication failure after editing
`POSTGRES_PASSWORD`, remember that changing the variable does not change the
password inside an already-initialized `pgdata` volume. Restore the old value
or change the PostgreSQL role password deliberately.

## Compose refuses to start before creating containers

**Symptom:** `docker compose up` reports `set POSTGRES_PASSWORD in .env`,
`generate with mix phx.gen.secret`, or `generate with mix
superx.gen.vault_key`.

These are Compose interpolation guards for `POSTGRES_PASSWORD`,
`SECRET_KEY_BASE`, and `SUPERX_VAULT_KEY`. Fill them in `.env`. Empty values
count as missing. Then rerun:

```bash
docker compose config >/dev/null
docker compose up -d --build
```

A direct production release also raises if `DATABASE_URL`, `SECRET_KEY_BASE`,
or `SUPERX_VAULT_KEY` is absent. An invalid vault key raises
`SUPERX_VAULT_KEY must be exactly 32 bytes, base64-encoded`.

## Attachments previewed before a deploy but are now missing

**Symptom:** `/uploads/<id>` returns 404, previews disappear, or publishing
fails with “An attached file is missing from local storage.”

Post rows store durable opaque media keys, not file bytes. The corresponding
files must remain in `SUPERX_UPLOADS_DIR`. Compose mounts the named `uploads`
volume at `/app/uploads`.

Check the mount and files without changing them:

```bash
docker compose config
docker compose exec app sh -c 'ls -ld /app/uploads && find /app/uploads -maxdepth 1 -type f | head'
```

Typical causes are starting the release without the volume, changing
`SUPERX_UPLOADS_DIR`, deleting the Compose project with `down -v`, or restoring
only PostgreSQL. Restore the matching uploads backup. See
[Deployment](DEPLOYMENT.md#backups).

## A scheduled post is late or failed partway through a thread

**Symptom:** A due post waits up to a minute, is delayed after a rate limit, or
a thread shows only its first segments on X.

The dispatcher runs once per minute, so sub-minute precision is not promised.
X 429 responses return the row to `scheduled` and snooze its job until the
reported reset, capped at 15 minutes.

If a thread fails after publishing some segments, SuperX records the X IDs,
marks it failed, and deliberately does not retry. A full retry would duplicate
the segments already live. Open the Failed tab and finish the thread manually
from the last published X post.

For other failures, the Failed tab contains the normalized X error. Reconnect
on authorization errors, restore missing media, or fix a permanent 4xx before
creating a new attempt.

## Related reference

- [Setup](SETUP.md)
- [Configuration](CONFIGURATION.md)
- [Deployment](DEPLOYMENT.md)
- [Architecture](ARCHITECTURE.md)
- [FAQ](FAQ.md)
