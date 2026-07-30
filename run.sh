#!/usr/bin/env bash
# Boots the dev server with every configured integration live.
# Reads .env without exporting the empty placeholders that would fail
# validation (SUPERX_VAULT_KEY is derived in dev when unset).
set -euo pipefail
cd "$(dirname "$0")"

while IFS='=' read -r key value; do
  [[ "$key" =~ ^[A-Z_]+$ ]] || continue
  [[ -n "$value" ]] || continue
  export "$key=$value"
done < <(grep -E '^[A-Z_]+=' .env)

exec mix phx.server
