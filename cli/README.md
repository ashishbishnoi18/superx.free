# superx-free

`superx-free` is the dependency-free command-line client for a SuperX
instance. It reads the selected X account, creates drafts, and schedules
approved drafts through the same API as the web application. It does not
publish directly to X.

Node 20 or newer is required.

## Install

After the package is published:

```bash
npm install --global superx-free
```

To install it from a project checkout before publication:

```bash
npm install --global ./cli
```

Both forms install the `superx-free` binary. The package has no runtime
dependencies beyond Node.

## Login

Create a token under **Accounts → API access** in SuperX, then run:

```bash
superx-free login
```

The token prompt is hidden. A self-hosted instance can be selected explicitly:

```bash
superx-free login --host https://superx.example
```

The default host is `https://superx.free`. Login verifies the credential and
stores the host and token in `~/.superx-free/config.json`; the directory is
owner-only and the file is written with `0600` permissions. For unattended
setup, login can read the token from standard input or `SUPERX_FREE_TOKEN`.
Avoid putting a token in a shell argument.

The CLI never prints the token.

## Machine-readable output

Add `--json` to any command. Successful read and write commands return the API
response as JSON, while `whoami`, `login`, `logout`, and `delete` return small
command-specific objects. Errors are written to standard error; with `--json`
they are JSON too.

```bash
superx-free queue --status scheduled --json
```

## Commands

### `login`

Store and verify an API token. Pass `--host URL` for a host other than
`https://superx.free`.

```bash
superx-free login [--host https://superx.example]
```

A valid token can log in even when no X account is selected yet. Other
commands that need an account will report that state plainly.

### `logout`

Remove the local config file. This does not revoke the token in SuperX; revoke
it under Accounts when it should stop working everywhere.

```bash
superx-free logout
```

### `whoami`

Show the host and currently selected X account.

```bash
superx-free whoami
```

### `queue`

List posts in one lifecycle state. The default is `scheduled`; supported
states are `draft`, `scheduled`, `publishing`, `posted`, `failed`, and
`cancelled`.

```bash
superx-free queue
superx-free queue --status draft
superx-free queue --status posted --json
```

### `shelf`

List generated drafts in **Ready to Post**, with the same per-kind counts as
the web application. This is a read-only view; CLI-created drafts go to the
Queue's Drafts state.

```bash
superx-free shelf
```

### `analytics`

Show aggregate analytics over 7, 30, or 90 days. The default is 30.

```bash
superx-free analytics
superx-free analytics --days 90 --json
```

### `draft`

Create a draft. Quote text so the shell passes it as one value:

```bash
superx-free draft "The post text"
```

For a thread, repeat `--segment` in publication order:

```bash
superx-free draft \
  --segment "The opening post" \
  --segment "The second post" \
  --segment "The closing post"
```

A positional text value becomes the first segment when it is combined with
`--segment`. Tags are optional and repeatable:

```bash
superx-free draft "A product note" --tag product --tag launch
```

SuperX applies the same validation as the composer, including the 280-character
limit for each segment. The command always creates a draft; it cannot set a
post to scheduled or posted.

### `schedule`

Schedule an owned draft into the next open recurring slot:

```bash
superx-free schedule POST_ID
```

Or choose an unoccupied future time with an ISO 8601 datetime:

```bash
superx-free schedule POST_ID --at 2030-08-02T09:30:00Z
```

Only drafts can be scheduled. Scheduling is intended to follow human review;
there is no direct publish command or publish endpoint.

### `delete`

Delete an owned post record from SuperX:

```bash
superx-free delete POST_ID
```

Interactive use asks for confirmation. In a non-interactive shell, make the
decision explicit:

```bash
superx-free delete POST_ID --yes --json
```

This never deletes a post from X, including when the SuperX record is already
marked posted.

## Expected failures

- With no local config, the CLI asks you to run `superx-free login`.
- A missing, invalid, or revoked token returns the API's 401 message without
  exposing the credential. Log in again with a current token.
- On a 429, the CLI waits for the server's `Retry-After` interval before a
  bounded retry. It does not loop tightly against the API.
- If the host cannot be reached within 15 seconds, the CLI identifies the host
  and exits without changing local account data.
- Validation, missing-post, and schedule-conflict messages are preserved from
  SuperX.

## Package checks

From this directory:

```bash
npm test
npm pack --dry-run
```

Publishing is deliberately left to the package owner.
