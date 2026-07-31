#!/usr/bin/env bash
# Ship the current commit to production.
#
# Transfers over a git bundle rather than a remote, because the server has
# no forge access and this needs no credentials beyond the SSH one you
# already have. Migrations run inside the container on boot, so there is
# no separate step to forget.
#
#   ./deploy.sh            # deploy HEAD
#   HOST=other ./deploy.sh # deploy somewhere else
set -euo pipefail

HOST="${HOST:-kit}"
DIR="${DIR:-/var/www/superx.free}"
BUNDLE="$(mktemp -t superx-XXXXXX.bundle)"
trap 'rm -f "$BUNDLE"' EXIT

cd "$(dirname "$0")"

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit first — the bundle ships commits, not files." >&2
  exit 1
fi

echo "→ bundling $(git log --oneline -1)"
git bundle create "$BUNDLE" --all >/dev/null 2>&1

echo "→ sending to $HOST"
scp -q "$BUNDLE" "$HOST:/tmp/superx.bundle"

echo "→ building and restarting"
# Fetch into a remote-tracking ref: git refuses to fetch directly into the
# branch that is checked out on the server.
ssh "$HOST" "set -e
  cd $DIR
  git fetch -q /tmp/superx.bundle '+refs/heads/main:refs/remotes/bundle/main'
  git reset -q --hard bundle/main
  docker compose build app 2>&1 | tail -2
  docker compose up -d --force-recreate app 2>&1 | grep -v '^time=' | tail -3
  rm -f /tmp/superx.bundle"

echo "→ waiting for health"
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' https://superx.free/ || true)"
  if [ "$code" = "200" ]; then
    echo "✓ live: https://superx.free ($code)"
    exit 0
  fi
  sleep 3
done

echo "✗ did not come up; check: ssh $HOST 'cd $DIR && docker compose logs app | tail -40'" >&2
exit 1
