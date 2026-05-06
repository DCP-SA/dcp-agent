#!/bin/bash
# DCP GPU Thermal Monitor — runs every 60s
set -euo pipefail

DCP_DIR="$HOME/.dcp"
LOG="$DCP_DIR/logs/gpu.log"
mkdir -p "$DCP_DIR/logs"

if command -v nvidia-smi &>/dev/null; then
  TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1)
  UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
  VRAM_USED=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1)
  VRAM_TOTAL=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
  POWER=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | head -1)

  VRAM_PCT=$((VRAM_USED * 100 / VRAM_TOTAL))

  if [ "${TEMP:-0}" -gt 90 ]; then
    echo "[$(date -u +%H:%M:%S)] CRITICAL: GPU temp ${TEMP}C — throttling!" >> "$LOG"
    # Ollama will self-throttle via NVIDIA driver, but log it
  elif [ "${TEMP:-0}" -gt 80 ]; then
    echo "[$(date -u +%H:%M:%S)] WARN: GPU temp ${TEMP}C" >> "$LOG"
  fi

  if [ "$VRAM_PCT" -gt 95 ]; then
    echo "[$(date -u +%H:%M:%S)] WARN: VRAM ${VRAM_PCT}% (${VRAM_USED}/${VRAM_TOTAL}MB)" >> "$LOG"
  fi

elif [[ "$(uname)" == "Darwin" ]]; then
  # Apple Silicon — check via powermetrics (requires sudo)
  sudo powermetrics --samplers gpu_power -i 1000 -n 1 2>/dev/null | grep -E "GPU|power" > /tmp/dcp-gpu-sample.txt 2>/dev/null || true
fi
