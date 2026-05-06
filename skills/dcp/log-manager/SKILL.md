---
name: dcp-log-manager
description: "Rotate logs, compress old ones, prevent disk fill from agent activity."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, logs, rotation, cleanup, disk]
---

# DCP Log Manager

Manage all DCP agent logs to prevent disk from filling up.

## Log locations

| Log | Path | Source |
|-----|------|--------|
| Agent main | ~/.dcp/agent.log | launchd/systemd stdout |
| Agent errors | ~/.dcp/agent.err | launchd/systemd stderr |
| Ollama | ~/.dcp/logs/ollama.log | Ollama serve output |
| WireGuard watchdog | ~/.dcp/logs/watchdog-wg.log | Cron script |
| Ollama watchdog | ~/.dcp/logs/watchdog-ollama.log | Cron script |
| Wake recovery | ~/.dcp/logs/wake.log | Power management |
| Diagnostics | ~/.dcp/logs/diagnostics/ | Network diagnostics |

## Rotation rules

```bash
#!/bin/bash
# Run daily at 3am AST via cron
LOG_DIR="$HOME/.dcp/logs"
AGENT_LOG="$HOME/.dcp/agent.log"
AGENT_ERR="$HOME/.dcp/agent.err"
MAX_SIZE_MB=50
KEEP_DAYS=7
KEEP_COMPRESSED=30

mkdir -p "$LOG_DIR/archive"

rotate_log() {
  local LOG_FILE="$1"
  local SIZE_KB=$(du -k "$LOG_FILE" 2>/dev/null | awk '{print $1}')

  if [ "${SIZE_KB:-0}" -gt $((MAX_SIZE_MB * 1024)) ]; then
    local TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    local BASENAME=$(basename "$LOG_FILE")
    mv "$LOG_FILE" "$LOG_DIR/archive/${BASENAME}.${TIMESTAMP}"
    gzip "$LOG_DIR/archive/${BASENAME}.${TIMESTAMP}" 2>/dev/null
    touch "$LOG_FILE"
    echo "Rotated $LOG_FILE (was ${SIZE_KB}KB)"
  fi
}

# Rotate all logs
rotate_log "$AGENT_LOG"
rotate_log "$AGENT_ERR"

for LOG in "$LOG_DIR"/*.log; do
  [ -f "$LOG" ] && rotate_log "$LOG"
done

# Delete uncompressed archives older than KEEP_DAYS
find "$LOG_DIR/archive" -name "*.log.*" -not -name "*.gz" -mtime +$KEEP_DAYS -delete 2>/dev/null

# Delete compressed archives older than KEEP_COMPRESSED
find "$LOG_DIR/archive" -name "*.gz" -mtime +$KEEP_COMPRESSED -delete 2>/dev/null

# Report disk savings
ARCHIVE_SIZE=$(du -sh "$LOG_DIR/archive" 2>/dev/null | awk '{print $1}')
echo "Archive size: $ARCHIVE_SIZE"
```

## Disk space monitoring

```bash
# Check overall disk usage
DISK_PCT=$(df -h / | awk 'NR==2{print $5}' | tr -d '%')

if [ "$DISK_PCT" -gt 95 ]; then
  echo "CRITICAL: Disk ${DISK_PCT}% full"
  # Emergency cleanup
  rm -rf "$HOME/.dcp/logs/archive"/*.gz 2>/dev/null
  # Remove Ollama temp/cache
  rm -rf /tmp/ollama* 2>/dev/null
  # Remove old model blobs (keep only current models)
  ollama list 2>/dev/null | awk '{print $1}' > /tmp/dcp-keep-models.txt
  # Report to backend
  curl -s -X POST https://api.dcp.sa/api/providers/heartbeat \
    -H "Authorization: Bearer $DCP_PROVIDER_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"disk_warning\": true, \"disk_pct\": $DISK_PCT}"

elif [ "$DISK_PCT" -gt 90 ]; then
  echo "WARNING: Disk ${DISK_PCT}% full"
  # Aggressive rotation
  find "$HOME/.dcp/logs/archive" -name "*.gz" -mtime +7 -delete 2>/dev/null
fi
```

## Ollama model cache cleanup

```bash
# Ollama stores models in ~/.ollama/models
OLLAMA_DIR="${OLLAMA_MODELS:-$HOME/.ollama/models}"
OLLAMA_SIZE=$(du -sh "$OLLAMA_DIR" 2>/dev/null | awk '{print $1}')
echo "Ollama models: $OLLAMA_SIZE"

# List models sorted by last access (remove least-used if disk tight)
# This is a last resort — only when disk >90%
```

## Hermes log cleanup

```bash
# Hermes stores session logs in ~/.hermes/
HERMES_DIR="$HOME/.hermes"
if [ -d "$HERMES_DIR/sessions" ]; then
  # Keep only last 50 sessions
  ls -t "$HERMES_DIR/sessions" 2>/dev/null | tail -n +51 | xargs -I{} rm -rf "$HERMES_DIR/sessions/{}" 2>/dev/null
fi
```

## Schedule

- **Light rotation**: Daily at 3am AST
- **Disk check**: Every 6 hours
- **Emergency cleanup**: Triggered when disk >95%
