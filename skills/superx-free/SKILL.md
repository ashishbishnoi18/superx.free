---
name: superx-free
description: Operate a selected X account through the superx-free CLI by reading its queue, review shelf, and aggregate analytics; creating drafts; scheduling explicitly approved drafts; and deleting SuperX records. Use when a user asks an agent to inspect what has worked, prepare X posts or threads for review, manage the SuperX queue, or report account performance without publishing directly.
---

# SuperX Free

Use `superx-free` as the only interface. Add `--json` to every command whose output you need to inspect or transform.

## Establish context

1. Run `superx-free whoami --json` and name the selected account before making changes. Stop if it is not the account the user intended.
2. If the CLI is not logged in, ask the user to run `superx-free login` in their own terminal. Never request, display, or handle their API token in conversation.
3. Read before writing:
   - Run `superx-free analytics --days 30 --json` for aggregate performance.
   - Run `superx-free queue --status posted --json` to study posts already recorded as posted.
   - Run `superx-free shelf --json` to inspect generated drafts already waiting for review.
4. Derive themes, structures, and voice from those results. Do not claim that aggregate analytics identifies which individual post performed best.

## Prepare drafts

Create one post:

```bash
superx-free draft "The complete post text" --json
```

Create a thread by repeating `--segment` in order:

```bash
superx-free draft --segment "Opening post" --segment "Second post" --segment "Closing post" --json
```

Add repeatable `--tag TAG` values only when they help the user's organisation.

Treat the returned post as a draft awaiting human review. The `draft` command writes to the Queue's Drafts state; `shelf` is a read-only view of generated Ready to Post items. Do not say a CLI-created draft was added to that shelf.

## Schedule only after approval

Never schedule newly generated copy without explicit user approval. After approval, schedule it into the next configured opening:

```bash
superx-free schedule POST_ID --json
```

Use an explicit future ISO 8601 time only when the user supplied or approved it:

```bash
superx-free schedule POST_ID --at 2030-08-02T09:30:00Z --json
```

Scheduling is the furthest this CLI can act. A scheduled post may later publish through SuperX's existing worker, but there is no CLI or API command for direct publication.

## Read and remove records

Use `queue --status draft|scheduled|publishing|posted|failed|cancelled --json` to inspect one lifecycle state. Use `analytics --days 7|30|90 --json` for a supported reporting window.

Delete only when the user explicitly asks. In unattended use, confirmation must be explicit:

```bash
superx-free delete POST_ID --yes --json
```

Deletion removes the owned record from SuperX. It never deletes a post from X, including when that record is already marked posted.

## Report honestly

- Never claim to have published directly. No publish endpoint exists.
- Say “scheduled” only after `schedule` succeeds. Say “posted” only when a later `queue --status posted` response contains the post.
- Preserve API validation messages instead of silently rewriting rejected copy.
- Let the CLI honour rate-limit delays. On a 401, ask the user to log in again; on an unreachable host, report the host or network problem without guessing about account state.
