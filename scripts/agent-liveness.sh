#!/bin/bash
# agent-liveness.sh
# Hermes liveness beacon -- runs every minute via cron.
#
# Reports a small heartbeat to the DCP backend so the dashboard can show
# "agent alive" without waiting for dcp_daemon.py's heavier heartbeat.
# This is intentionally lightweight: no GPU probes, no model checks.
#
# Idempotent: rerunning never duplicates state. Writes a single timestamp
# file at ~/.dcp/agent-liveness.last for local debugging.

set -u

DCP_DIR="${DCP_DIR:-$HOME/.dcp}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

# Source provider env (DCP_PROVIDER_KEY, DCP_API_BASE, DCP_PROVIDER_ID).
if [ -f "$HERMES_HOME/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$HERMES_HOME/.env"
    set +a
fi

API_BASE="${DCP_API_BASE:-${DCP_API_URL:-https://api.dcp.sa}}"
KEY="${DCP_PROVIDER_KEY:-}"
PID_ID="${DCP_PROVIDER_ID:-}"

mkdir -p "$DCP_DIR"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$DCP_DIR/agent-liveness.last"

if [ -z "$KEY" ]; then
    # Nothing to report yet -- provider not registered.
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    exit 0
fi

# Compose payload. Backend accepts shape: {"provider_id": "...", "ts": "..."}.
TS="$(date -u +%s)"
PAYLOAD="{\"provider_id\":\"${PID_ID}\",\"ts\":${TS},\"source\":\"agent-liveness\"}"

# Fire-and-forget: 5s timeout, no retries, errors go to stderr (cron logs).
curl -fsS --max-time 5 \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -X POST \
    --data "$PAYLOAD" \
    "$API_BASE/api/providers/liveness" \
    >> "$DCP_DIR/liveness.log" 2>&1 || true

exit 0
