#!/bin/bash
# DCP Agent Heartbeat — runs every 30s
# Reports provider status to DCP backend
set -euo pipefail

DCP_DIR="$HOME/.dcp"
STATE="$DCP_DIR/agent-state.json"
LOG="$DCP_DIR/logs/heartbeat.log"
PROVIDER_KEY="${DCP_PROVIDER_KEY:-$(grep DCP_PROVIDER_KEY "$DCP_DIR/agent/.env" 2>/dev/null | cut -d= -f2)}"

mkdir -p "$DCP_DIR/logs"

# Collect GPU info
GPU_MODEL="" GPU_TEMP=0 GPU_VRAM_USED=0 GPU_VRAM_TOTAL=0 GPU_UTIL=0

if command -v nvidia-smi &>/dev/null; then
  IFS=', ' read -r GPU_MODEL GPU_TEMP GPU_VRAM_USED GPU_VRAM_TOTAL GPU_UTIL <<< \
    "$(nvidia-smi --query-gpu=name,temperature.gpu,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)"
elif [[ "$(uname)" == "Darwin" ]]; then
  GPU_MODEL=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Chipset Model" | awk -F: '{print $2}' | xargs)
  GPU_VRAM_TOTAL=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024)}')
fi

# Collect models
MODELS_JSON=$(curl -sf http://localhost:11434/api/tags 2>/dev/null | python3 -c "import sys,json;print(json.dumps([m['name'] for m in json.load(sys.stdin).get('models',[])]))" 2>/dev/null || echo '[]')

# Collect WireGuard mesh IP
WG_IP=$(ip addr show wg0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || \
        ifconfig utun0 2>/dev/null | grep "inet " | awk '{print $2}' || echo "")

# Uptime
UPTIME_S=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || python3 -c "import time,os;print(int(time.time()-os.stat('/').st_ctime))" 2>/dev/null || echo 0)

# Send heartbeat
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST https://api.dcp.sa/api/providers/heartbeat \
  -H "Authorization: Bearer $PROVIDER_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"status\": \"online\",
    \"daemon_version\": \"agent-1.0.0\",
    \"gpu_model\": \"$GPU_MODEL\",
    \"gpu_temp_c\": ${GPU_TEMP:-0},
    \"gpu_vram_used_mb\": ${GPU_VRAM_USED:-0},
    \"gpu_vram_total_mb\": ${GPU_VRAM_TOTAL:-0},
    \"gpu_utilization_pct\": ${GPU_UTIL:-0},
    \"models_available\": $MODELS_JSON,
    \"wg_mesh_ip\": \"$WG_IP\",
    \"accepting_jobs\": true,
    \"uptime_seconds\": $UPTIME_S
  }" 2>/dev/null || echo "000")

# Update state file
python3 -c "
import json, os
from datetime import datetime
path = os.path.expanduser('$STATE')
s = {}
if os.path.exists(path):
    with open(path) as f: s = json.load(f)
s['last_heartbeat'] = datetime.utcnow().isoformat() + 'Z'
s['status'] = 'online'
s['gpu_temp'] = ${GPU_TEMP:-0}
s['models_loaded'] = $MODELS_JSON
with open(path, 'w') as f: json.dump(s, f, indent=2)
" 2>/dev/null

# Track failures
TRACKER="$DCP_DIR/failure-tracker.json"
if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
  echo "[$(date -u +%H:%M:%S)] Heartbeat FAILED ($HTTP_CODE)" >> "$LOG"
  python3 -c "
import json, os
from datetime import datetime
t = {}
p = os.path.expanduser('$TRACKER')
if os.path.exists(p):
    with open(p) as f: t = json.load(f)
hb = t.get('heartbeat', {'consecutive_fails':0,'total_fails_24h':0})
hb['consecutive_fails'] = hb.get('consecutive_fails',0) + 1
hb['last_fail'] = datetime.utcnow().isoformat() + 'Z'
hb['total_fails_24h'] = hb.get('total_fails_24h',0) + 1
t['heartbeat'] = hb
with open(p, 'w') as f: json.dump(t, f, indent=2)
if hb['consecutive_fails'] >= 3:
    print('ESCALATE: 3 consecutive heartbeat failures')
" 2>/dev/null
else
  # Reset failure counter on success
  python3 -c "
import json, os
p = os.path.expanduser('$TRACKER')
t = {}
if os.path.exists(p):
    with open(p) as f: t = json.load(f)
if 'heartbeat' in t: t['heartbeat']['consecutive_fails'] = 0
with open(p, 'w') as f: json.dump(t, f, indent=2)
" 2>/dev/null
fi
