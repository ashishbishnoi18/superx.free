# Contributing

Issues and pull requests are welcome. This file describes how the codebase
is written, so a change fits in rather than fighting it.

## Getting set up

Elixir 1.19 and Postgres 17+ with pgvector.

```bash
mix setup
mix superx.dev.seed     # demo user, corpus, shelf, analytics
mix phx.server
```

There is a Go worker in `scraper/`, but you do not need the Go toolchain
to work on this. It is a fallback read source that is only consulted when
twitterapi.io is unconfigured, and it does nothing without credentials
most people should not be using — see the note in the README.

The seed prints a sign-in URL. You can work on every screen without an X
account, an LLM key, or spending anything.

Before opening a PR:

```bash
mix precommit    # format, compile with warnings as errors, run the tests
```

## How this codebase is written

**Comments explain why, not what.** If a comment restates the code, delete
it. The ones worth writing look like this:

```elixir
# Six, not five: at five this fires on ordinary idiom — "one of the
# things that" is exactly five words and appears in unrelated posts all
# the time.
@ngram 6
```

Moduledocs explain the decision a module embodies, not a list of its
functions.

**Tests concentrate where being wrong costs something.** Money spent, data
lost, someone else's content published under a user's name. A test that
asserts the framework works is noise.

More importantly: **a test must fail before the fix.** Several bugs here
shipped with passing tests that encoded the same wrong assumption as the
code. If you write a test alongside a fix, check it actually fails when you
revert the fix.

**Verify APIs against the live service, not the documentation.** This
project has been bitten repeatedly by upstream docs that were confidently
wrong — a media upload endpoint documented in a format that fails at the
second step, a replies endpoint documented as returning a field it does
not. Where behaviour was checked against the real API, the comment says so.

**Integrations degrade, they do not crash.** Every external service is
optional. Missing an LLM key disables drafting and leaves everything else
working. Keep that property.

**Nothing publishes without human approval.** The API, the MCP server and
Ask can all draft and queue. None of them can post. This is deliberate and
not up for negotiation in a PR.

## Design

The interface follows an editorial style: hairlines and air, no frames, no
shadows. Colours come from CSS custom properties exposed as Tailwind
utilities — `text-faint`, `border-border`, `bg-card`, `text-primary`. Never
hardcode a hex value or a `gray-500`; if a utility does not exist, add the
token in `@theme inline` rather than inlining a colour. Dark mode works
because everything uses tokens.

Reuse the existing components — `.post`, `.metrics`, `<.page_header>`,
`.act` / `.act-key` for buttons, `.nb-mono` for numerals.

Every screen needs a real empty state, written in the same plain voice as
the rest of the app. "Nothing here" is not enough when the honest answer is
"nothing has run yet" or "this needs configuring".

## Prose style

British spelling in comments and documentation — normalised, behaviour,
recognised. No emoji. Short sentences.

## Reporting security issues

Please read [SECURITY.md](SECURITY.md) rather than opening a public issue.
