#!/bin/bash
# DCP Disk Cleanup — runs every 6h, emergency on >95%
set -uo pipefail

DCP_DIR="$HOME/.dcp"
LOG_DIR="$DCP_DIR/logs"
ARCHIVE="$LOG_DIR/archive"
MAX_SIZE_MB=50
KEEP_DAYS=7
KEEP_COMPRESSED=30

mkdir -p "$ARCHIVE"

rotate_log() {
  local f="$1"
  local size_kb=$(du -k "$f" 2>/dev/null | awk '{print $1}')
  if [ "${size_kb:-0}" -gt $((MAX_SIZE_MB * 1024)) ]; then
    local ts=$(date +%Y%m%d-%H%M%S)
    local base=$(basename "$f")
    mv "$f" "$ARCHIVE/${base}.${ts}"
    gzip "$ARCHIVE/${base}.${ts}" 2>/dev/null
    touch "$f"
  fi
}

# Rotate all logs
for log in "$DCP_DIR/agent.log" "$DCP_DIR/agent.err" "$LOG_DIR"/*.log; do
  [ -f "$log" ] && rotate_log "$log"
done

# Delete old archives
find "$ARCHIVE" -name "*.log.*" -not -name "*.gz" -mtime +$KEEP_DAYS -delete 2>/dev/null
find "$ARCHIVE" -name "*.gz" -mtime +$KEEP_COMPRESSED -delete 2>/dev/null

# Clean Hermes sessions (keep last 50)
if [ -d "$HOME/.hermes/sessions" ]; then
  ls -t "$HOME/.hermes/sessions" 2>/dev/null | tail -n +51 | while read d; do
    rm -rf "$HOME/.hermes/sessions/$d" 2>/dev/null
  done
fi

# Clean /tmp ollama artifacts
find /tmp -maxdepth 1 -name "ollama*" -mtime +1 -exec rm -rf {} \; 2>/dev/null

# Report
DISK_PCT=$(df -h / | awk 'NR==2{print $5}' | tr -d '%')
echo "[$(date -u +%H:%M:%S)] Disk cleanup done. Usage: ${DISK_PCT}%"
