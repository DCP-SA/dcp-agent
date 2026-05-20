#!/bin/bash
# DCP Self-Update — runs every 6h
#
# Hardened 2026-05-20: replaces unsigned `git pull origin main` with a
# manifest-pinned update flow. The manifest at api.dcp.sa/agent/manifest.json
# carries the safe commit SHA that providers should converge to. Backend
# (which Peter alone publishes from) is the trust anchor. A rogue merge to
# the GitHub repo cannot propagate until the manifest is updated.
#
# Manifest shape (served by api.dcp.sa):
#   {
#     "safe_commit": "<40-char SHA>",
#     "min_tag":     "<optional minimum tag, e.g. v0.6.0>",
#     "rollout_pct": <0-100 — staged rollout cap>,
#     "published_at": "<ISO timestamp>"
#   }
#
# Provider only updates if:
#   - Manifest fetch succeeds (HTTPS + provider key auth)
#   - safe_commit is reachable in origin (we fetched it)
#   - This provider falls within rollout_pct (deterministic hash of provider_id)
#
set -uo pipefail

DCP_DIR="$HOME/.dcp"
AGENT_DIR="$DCP_DIR/agent"
LOG="$DCP_DIR/logs/update.log"
LOCKFILE="$DCP_DIR/cron.lock"
ENV_FILE="$AGENT_DIR/.env"

mkdir -p "$DCP_DIR/logs"

# Exclusive lock — don't run during other heavy operations
exec 200>"$LOCKFILE"
flock -n 200 || { echo "[$(date -u +%H:%M:%S)] Locked, skipping update" >> "$LOG"; exit 0; }

cd "$AGENT_DIR"

# Load DCP credentials (DCP_PROVIDER_ID, DCP_API_KEY, optional DCP_MANIFEST_URL)
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

MANIFEST_URL="${DCP_MANIFEST_URL:-https://api.dcp.sa/agent/manifest.json}"
PROVIDER_ID="${DCP_PROVIDER_ID:-}"
API_KEY="${DCP_API_KEY:-}"

if [ -z "$PROVIDER_ID" ] || [ -z "$API_KEY" ]; then
  echo "[$(date -u +%H:%M:%S)] Missing DCP_PROVIDER_ID or DCP_API_KEY in .env; skipping update" >> "$LOG"
  exit 0
fi

# Fetch manifest from api.dcp.sa (authenticated, HTTPS-pinned)
MANIFEST=$(curl -sfS --max-time 15 \
  -H "Authorization: Bearer $API_KEY" \
  -H "x-provider-id: $PROVIDER_ID" \
  "$MANIFEST_URL" 2>>"$LOG")

if [ -z "$MANIFEST" ]; then
  echo "[$(date -u +%H:%M:%S)] Manifest fetch failed; staying on current commit" >> "$LOG"
  exit 0
fi

SAFE_COMMIT=$(echo "$MANIFEST" | python3 -c "import sys,json; print(json.load(sys.stdin).get('safe_commit',''))" 2>/dev/null)
ROLLOUT_PCT=$(echo "$MANIFEST" | python3 -c "import sys,json; print(json.load(sys.stdin).get('rollout_pct', 0))" 2>/dev/null)

# safe_commit must be a 40-char hex SHA
if ! echo "$SAFE_COMMIT" | grep -qE '^[0-9a-f]{40}$'; then
  echo "[$(date -u +%H:%M:%S)] Manifest safe_commit malformed ('$SAFE_COMMIT'); aborting" >> "$LOG"
  exit 0
fi

# Staged-rollout gate: deterministic per provider_id, so the same provider
# stays in the same percentile across runs. 100 = full fleet, 10 = canary.
PROVIDER_BUCKET=$(printf '%s' "$PROVIDER_ID" | python3 -c "import hashlib,sys; print(int(hashlib.sha256(sys.stdin.read().encode()).hexdigest(),16) % 100)" 2>/dev/null || echo 100)
if [ "$PROVIDER_BUCKET" -ge "$ROLLOUT_PCT" ]; then
  echo "[$(date -u +%H:%M:%S)] Provider bucket=$PROVIDER_BUCKET >= rollout_pct=$ROLLOUT_PCT; deferring" >> "$LOG"
  exit 0
fi

# Fetch the safe commit. Only what we need; don't update local refs yet.
git fetch origin --quiet 2>>"$LOG"
if ! git cat-file -e "$SAFE_COMMIT" 2>/dev/null; then
  echo "[$(date -u +%H:%M:%S)] safe_commit $SAFE_COMMIT not reachable from origin; aborting" >> "$LOG"
  exit 0
fi

LOCAL=$(git rev-parse HEAD 2>/dev/null)
if [ "$LOCAL" == "$SAFE_COMMIT" ]; then
  exit 0
fi

# Don't update during active inference
ACTIVE=$(curl -sf --max-time 5 http://localhost:11434/api/ps 2>/dev/null | python3 -c "
import sys,json
try:
    ps=json.load(sys.stdin)
    print(len([m for m in ps.get('models',[]) if m.get('size_vram',0)>0]))
except Exception:
    print(0)
" 2>/dev/null || echo "0")

if [ "$ACTIVE" -gt 0 ]; then
  echo "[$(date -u +%H:%M:%S)] Inference active, deferring update" >> "$LOG"
  exit 0
fi

echo "[$(date -u +%H:%M:%S)] Update: $LOCAL -> $SAFE_COMMIT (rollout=$ROLLOUT_PCT, bucket=$PROVIDER_BUCKET)" >> "$LOG"

# Detached checkout — never auto-merges arbitrary work into local main
git stash --include-untracked >/dev/null 2>&1
git checkout --quiet "$SAFE_COMMIT" 2>>"$LOG"

# Check if deps changed
if git diff "$LOCAL..$SAFE_COMMIT" --name-only | grep -qE "setup.py|setup.cfg|pyproject.toml|requirements"; then
  echo "[$(date -u +%H:%M:%S)] Reinstalling deps..." >> "$LOG"
  # shellcheck disable=SC1091
  source .venv/bin/activate
  uv pip install -e . >> "$LOG" 2>&1 || pip install -e . >> "$LOG" 2>&1
fi

# Check if core code changed (needs restart)
if git diff "$LOCAL..$SAFE_COMMIT" --name-only | grep -qE "hermes_cli/|gateway"; then
  echo "[$(date -u +%H:%M:%S)] Core changed - triggering restart" >> "$LOG"
  exit 1  # Non-zero exit triggers service manager restart
fi

echo "[$(date -u +%H:%M:%S)] Updated, no restart needed" >> "$LOG"
