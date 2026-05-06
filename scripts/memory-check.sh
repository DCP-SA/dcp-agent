#!/bin/bash
# DCP Memory Check — runs every 2min
set -uo pipefail

DCP_DIR="$HOME/.dcp"
LOG="$DCP_DIR/logs/memory.log"
mkdir -p "$DCP_DIR/logs"

if [[ "$(uname)" == "Darwin" ]]; then
  # macOS — check memory pressure
  PRESSURE=$(memory_pressure 2>/dev/null | grep "System-wide memory free percentage" | awk '{print $NF}' | tr -d '%')
  if [ "${PRESSURE:-100}" -lt 10 ]; then
    echo "[$(date -u +%H:%M:%S)] WARN: Memory pressure high (${PRESSURE}% free)" >> "$LOG"
  fi
elif [[ "$(uname)" == "Linux" ]]; then
  # Linux — check /proc/meminfo
  TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  PCT=$((AVAIL * 100 / TOTAL))
  if [ "$PCT" -lt 10 ]; then
    echo "[$(date -u +%H:%M:%S)] WARN: RAM ${PCT}% available (${AVAIL}kB / ${TOTAL}kB)" >> "$LOG"
    # Check top memory consumers
    ps aux --sort=-%mem | head -5 >> "$LOG"
  fi
fi

# Check disk
DISK_PCT=$(df -h / | awk 'NR==2{print $5}' | tr -d '%')
if [ "${DISK_PCT:-0}" -gt 95 ]; then
  echo "[$(date -u +%H:%M:%S)] CRITICAL: Disk ${DISK_PCT}% full" >> "$LOG"
  # Emergency cleanup
  bash "$DCP_DIR/agent/scripts/disk-cleanup.sh" 2>/dev/null
elif [ "${DISK_PCT:-0}" -gt 90 ]; then
  echo "[$(date -u +%H:%M:%S)] WARN: Disk ${DISK_PCT}% full" >> "$LOG"
fi
