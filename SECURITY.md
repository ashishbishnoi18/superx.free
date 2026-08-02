# Security

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue.
Use GitHub's **Report a vulnerability** button under the Security tab, or
email the maintainer listed in the repository.

Include what you found, how to reproduce it, and what an attacker could do
with it. You will get a reply within a few days.

Because this is self-hosted software with no central service, there is
nothing for a maintainer to patch on your behalf — a fix means a release
and operators pulling it. Disclosures are handled with that in mind: fix
first, then announce clearly enough that operators know whether they are
affected and what to do.

## What this software holds

Anyone running an instance is holding real secrets. Worth knowing what:

- **X OAuth access and refresh tokens**, encrypted at rest with AES-256-GCM
  using `SUPERX_VAULT_KEY`. These grant the ability to post as the connected
  account.
- **XChat identity and signing keys**, held as an opaque Chat XDK blob and
  encrypted with the same vault. The blob is decrypted only across the local
  Node Port boundary and is excluded from inspected structs.
- **Private message text**, including locally decrypted XChat messages, stored
  in PostgreSQL so the inbox and drafting tools can use it. Protect database
  backups accordingly.
- **API keys** for twitterapi.io and your LLM provider, in the environment.
- **API tokens** for the read-write HTTP API, stored as a lookup prefix plus
  a SHA-256 hash of a separately generated secret. A database leak does not
  yield working tokens.
- **Session cookies**, signed, HTTP-only, `SameSite=Lax`.
- **Public share links** for analytics summaries and contact lists. These are
  unguessable capability URLs: anyone holding the link can read that view
  until it is revoked. They expose only whitelisted fields, and are excluded
  from `robots.txt`.
- **Contact records**, which are other people's handles and bios collected by
  a watch agent. Not your data — treat it accordingly.

## Running it safely

- **Back up `SUPERX_VAULT_KEY`,** and keep it out of version control. Losing
  it makes every stored token and XChat identity undecryptable. Accounts must
  reconnect, and their encrypted chat history may no longer be readable. It
  cannot be rotated in place.
- **Do not offer SuperX as a hosted service without redesigning XChat key
  custody.** This storage model is acceptable only because each operator runs
  their own instance. A host serving other people would hold their private
  keys, which X explicitly warns against.
- **Do not expose the app directly.** Bind it to localhost and put a reverse
  proxy with TLS in front. See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).
- **Keep `.env` at mode 600.** It contains every credential.
- **Do not commit `.env`.** It is gitignored; check before pushing a fork.
- **The API is rate limited per user**, not per token, so minting a new token
  does not reset the counter. Revoke tokens you are not using.
- **Set spend limits upstream.** Both X and twitterapi.io bill per use. A bug
  or a runaway loop costs real money; the providers' own caps are the
  backstop, and this app's own limits are configurable.

## Scope

In scope: authentication and session handling, token storage and encryption,
the API and MCP authentication paths, share-link authorisation, tenant
isolation between users and X accounts, and anything that could publish
without approval.

Out of scope: vulnerabilities in X, twitterapi.io or an LLM provider;
issues that require an attacker to already have shell access to the host or
the database; and anything arising from running with `SUPERX_DEFAULT_TIER`
deliberately set to bypass quotas.
