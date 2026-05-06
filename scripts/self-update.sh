#!/bin/bash
# DCP Self-Update — runs every 6h
set -uo pipefail

DCP_DIR="$HOME/.dcp"
AGENT_DIR="$DCP_DIR/agent"
LOG="$DCP_DIR/logs/update.log"
LOCKFILE="$DCP_DIR/cron.lock"

mkdir -p "$DCP_DIR/logs"

# Exclusive lock — don't run during other heavy operations
exec 200>"$LOCKFILE"
flock -n 200 || { echo "[$(date -u +%H:%M:%S)] Locked, skipping update" >> "$LOG"; exit 0; }

cd "$AGENT_DIR"

# Fetch
git fetch origin main --quiet 2>/dev/null

LOCAL=$(git rev-parse HEAD 2>/dev/null)
REMOTE=$(git rev-parse origin/main 2>/dev/null)

if [ "$LOCAL" == "$REMOTE" ]; then
  exit 0
fi

BEHIND=$(git rev-list HEAD..origin/main --count 2>/dev/null)
echo "[$(date -u +%H:%M:%S)] Update: $BEHIND commits behind" >> "$LOG"

# Don't update during active inference
ACTIVE=$(curl -sf http://localhost:11434/api/ps 2>/dev/null | python3 -c "
import sys,json
ps=json.load(sys.stdin)
print(len([m for m in ps.get('models',[]) if m.get('size_vram',0)>0]))
" 2>/dev/null || echo "0")

if [ "$ACTIVE" -gt 0 ]; then
  echo "[$(date -u +%H:%M:%S)] Inference active, deferring update" >> "$LOG"
  exit 0
fi

# Pull
git stash 2>/dev/null
git pull --ff-only origin main >> "$LOG" 2>&1

# Check if deps changed
if git diff "$LOCAL"..HEAD --name-only | grep -qE "setup.py|setup.cfg|pyproject.toml|requirements"; then
  echo "[$(date -u +%H:%M:%S)] Reinstalling deps..." >> "$LOG"
  source .venv/bin/activate
  uv pip install -e . >> "$LOG" 2>&1 || pip install -e . >> "$LOG" 2>&1
fi

# Check if core code changed (needs restart)
if git diff "$LOCAL"..HEAD --name-only | grep -qE "hermes_cli/|gateway"; then
  echo "[$(date -u +%H:%M:%S)] Core changed — triggering restart" >> "$LOG"
  exit 1  # Non-zero exit triggers service manager restart
fi

echo "[$(date -u +%H:%M:%S)] Updated, no restart needed" >> "$LOG"
