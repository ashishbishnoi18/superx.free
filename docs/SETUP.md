# Setup

Getting SuperX running from nothing. Budget about twenty minutes, most of
it waiting on X's developer signup.

You need Docker and Docker Compose. Everything else runs in containers.

If you only want to look around, skip to [Trying it without any
keys](#trying-it-without-any-keys) at the bottom — you can exercise every
screen with seeded data and no accounts at all.

---

## 1. Get the code

```bash
git clone https://github.com/ashishbishnoi18/superx.git
cd superx
cp .env.example .env
```

Open `.env` in an editor. You will fill it in as you go.

## 2. Generate the two local secrets

These are yours and never leave the machine.

```bash
# SECRET_KEY_BASE — signs cookies and session tokens
docker run --rm hexpm/elixir:1.19.5-erlang-26.2.5.20-debian-trixie-20260610-slim \
  sh -c 'mix local.hex --force >/dev/null && mix phx.gen.secret'

# SUPERX_VAULT_KEY — encrypts stored OAuth tokens at rest
openssl rand -base64 32
```

Put them in `.env`:

```
SECRET_KEY_BASE=<first value>
SUPERX_VAULT_KEY=<second value>
POSTGRES_PASSWORD=<anything you like>
```

> **Back up `SUPERX_VAULT_KEY`.** It encrypts every stored X token. Lose it
> and every connected account has to reconnect. Rotating it is not
> supported — the old tokens simply stop decrypting.

## 3. Create an X developer app

This is the longest step and the only one that gates sign-in and
publishing.

1. Go to [console.x.com](https://console.x.com) and sign in with the X
   account you want to post from.
2. Sign up for the developer programme. You will be asked for an account
   name and a description of what you are building. Describe it honestly:
   a scheduling and drafting tool operating on your own account, reading
   your own posts and mentions, publishing only what you approve, using
   OAuth 2.0. You will have to accept the developer agreement.
3. Once through, open your app → **Keys & Tokens** → **OAuth 2.0 Keys** →
   **Set up**.
4. Configure it exactly like this:

   | Field | Value |
   |---|---|
   | App permissions | **Read and write** |
   | Type of App | **Web App, Automated App or Bot** (confidential client) |
   | Callback URI | `http://localhost:4000/auth/x/callback` |
   | Website URL | anything, e.g. `http://localhost:4000` |

   If you are deploying to a domain, add
   `https://your-domain/auth/x/callback` as a second callback now.

5. Save. You will be shown a **Client ID** and a **Client Secret**.

   > The secret is shown **once**. Copy it immediately. The reveal toggle
   > on the Keys page only ever shows the last few characters afterwards —
   > if you lose it you must regenerate, which invalidates the old one.

6. Put both in `.env`:

   ```
   X_CLIENT_ID=<client id>
   X_CLIENT_SECRET=<client secret>
   ```

### Add credit

X's API is **pay-per-use with no free tier**. Publishing fails on a zero
balance while sign-in keeps working, which is a confusing way to discover
the problem.

Go to **Billing → Credits** and add a little. Roughly:

| | |
|---|---|
| Publish a post | $0.015 |
| Publish a post containing a link | $0.200 |
| Read your own data | $0.001 |

$5 covers a few hundred posts. Turn on auto-recharge if you would rather
not think about it.

### If you want image attachments

Nothing extra to configure — the app requests the `media.write` scope
automatically. But note that if you connected an account *before* enabling
it, that account must reconnect, because its token predates the scope.

## 4. Get a twitterapi.io key

This powers the corpus, mentions, topic feeds and Signals. Without it the
app still runs; those features stay empty.

1. Sign up at [twitterapi.io](https://twitterapi.io).
2. Copy your API key from the dashboard.
3. Add credit. It bills **per record returned**, roughly $0.15 per 1,000
   posts. $10 goes a long way.
4. Put it in `.env`:

   ```
   TWITTERAPI_IO_KEY=<your key>
   ```

### Pace it to your plan

`TWITTERAPI_IO_MIN_INTERVAL_MS` spaces out calls so you do not earn 429s.

| Your plan | Set it to |
|---|---|
| Free, never paid (0.2 QPS) | `6000` |
| Paid credits, no subscription (3 QPS) | `400` |
| A QPS subscription | match what you bought |

Credits and QPS are **separate purchases** on twitterapi.io. Buying credits
does not raise your request rate.

## 5. Choose an LLM

Used for drafting posts and replies, deriving your voice, and scoring
leads. Without a key, generation is disabled and everything else works.

Both providers speak the same wire format, so this is just a base URL and
two model names.

**DeepSeek** — much cheaper, good enough for this:

```
SUPERX_LLM_PROVIDER=deepseek
DEEPSEEK_API_KEY=<key from platform.deepseek.com>
```

**Anthropic** — better writing, more expensive:

```
SUPERX_LLM_PROVIDER=anthropic
ANTHROPIC_API_KEY=<key from console.anthropic.com>
```

Leave `SUPERX_WRITER_MODEL` and `SUPERX_UTILITY_MODEL` blank unless you
want to override the defaults.

### Optional: better corpus search

```
VOYAGE_API_KEY=<key from voyageai.com>
```

Enables vector similarity search over the corpus. Without it, search falls
back to Postgres full-text, which is decent.

## 6. Set your tier

On a private instance you are paying your own bills, so there is no reason
to throttle yourself:

```
SUPERX_DEFAULT_TIER=ultra
```

Leave it as `free` only if you are hosting for other people.

## 7. Start it

```bash
docker compose up -d --build
```

First boot builds the image and runs migrations. Watch it come up:

```bash
docker compose logs -f app
```

Then open **http://localhost:4000** and click **Sign in with 𝕏**.

## 8. First run

1. **Sign in.** You will be sent to X to authorise, then back.
2. **Voice.** Let it read your recent posts — it derives how you write from
   your own timeline. Or write the description yourself.
3. **Schedule.** Pick your posting times. These are in your local time and
   survive daylight saving changes.
4. **Fill the library.** The corpus starts empty, so the writer has nothing
   to learn shapes from. Kick off an ingest:

   ```bash
   docker compose exec app /app/bin/superx rpc \
     'SuperX.Workers.CorpusRefresh.perform(%Oban.Job{args: %{}})'
   ```

   That queues one night's worth. It also runs automatically at 01:00 daily.
   Expect a few hundred usable templates after the first couple of runs.

5. **Write something.** Open **Ready to Post** and press *Write another*, or
   go to **Inspiration**, find a post you like, and draft from it.

---

## Trying it without any keys

You can exercise the whole interface with no accounts, no keys and no
spending:

```bash
mix setup
mix superx.dev.seed
mix phx.server
```

The seed creates a demo user, a corpus, a populated shelf and analytics
history, then prints a sign-in URL. Every screen works; nothing talks to X.

---

## Where next

- Something not working → [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
- Putting it on a server → [DEPLOYMENT.md](DEPLOYMENT.md)
- Every setting → [CONFIGURATION.md](CONFIGURATION.md)
- What it costs → [FAQ.md](FAQ.md)
