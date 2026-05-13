---
name: dcp-boot-sequence
description: "Full startup checklist — verify everything before reporting online."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, boot, startup, init, checklist]
    trigger: on_startup
---

# DCP Boot Sequence

> **AUTH NOTE for `/api/providers/heartbeat`:** the backend reads `api_key` from the JSON body, not from `Authorization: Bearer`. The Bearer header is ignored. Always include `"api_key": "$DCP_PROVIDER_KEY"` as the first field of your request body. Examples below may show the Bearer header — it's harmless but the body field is required.




Run this on every agent startup. Do NOT report "online" until every check passes.

## Pre-flight checklist

Execute these in order. If any step fails, attempt the fix. If fix fails, continue to next step but mark status as "degraded".

### Step 1: Detect platform
```bash
# Detect OS
OS="$(uname -s)"
case "$OS" in
  Darwin) PLATFORM="macos" ;;
  Linux)  PLATFORM="linux" ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
esac
echo "Platform: $PLATFORM"
```

### Step 2: Detect GPU
```bash
# NVIDIA
if command -v nvidia-smi &>/dev/null; then
  GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
  GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
  GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader | head -1)
  echo "GPU: $GPU_MODEL (${GPU_VRAM}MB VRAM, ${GPU_TEMP}C)"
fi

# Apple Silicon
if [[ "$PLATFORM" == "macos" ]]; then
  GPU_MODEL=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Chipset Model" | awk -F: '{print $2}' | xargs)
  # Unified memory — get total system RAM as proxy
  GPU_VRAM=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024)}')
  echo "GPU: $GPU_MODEL (${GPU_VRAM}MB unified)"
fi

# AMD ROCm
if command -v rocm-smi &>/dev/null; then
  GPU_MODEL=$(rocm-smi --showproductname 2>/dev/null | grep "Card" | head -1)
  echo "GPU: $GPU_MODEL"
fi
```
**If no GPU detected:** Report to backend as "no_gpu", do NOT try to serve inference.

### Step 3: Check Ollama
```bash
# Is Ollama installed?
command -v ollama &>/dev/null || { echo "Ollama not installed"; exit 1; }

# Is it running?
if ! curl -sf http://localhost:11434/ > /dev/null 2>&1; then
  echo "Starting Ollama..."
  OLLAMA_HOST=0.0.0.0 OLLAMA_KEEP_ALIVE=-1 nohup ollama serve > ~/.dcp/logs/ollama.log 2>&1 &
  sleep 5
fi

# Verify it responds
curl -sf http://localhost:11434/ > /dev/null && echo "Ollama: OK" || echo "Ollama: FAILED"
```

### Step 4: Check models loaded
```bash
MODELS=$(curl -s http://localhost:11434/api/tags | python3 -c "
import sys,json
try:
  tags = json.load(sys.stdin)
  for m in tags.get('models',[]):
    size_gb = m.get('size',0)/1e9
    print(f\"  {m['name']} ({size_gb:.1f}GB)\")
  print(f\"Total: {len(tags.get('models',[]))} models\")
except: print('No models found')
")
echo "$MODELS"
```
**If no models:** Trigger `dcp-model-auto-select` skill to pull appropriate models for VRAM.

### Step 5: Check WireGuard
```bash
# Ping the DCP gateway
if ping -c 1 -W 3 10.8.0.1 > /dev/null 2>&1; then
  echo "WireGuard: OK"
  WG_IP=$(ip addr show wg0 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 || ifconfig utun 2>/dev/null | grep "inet " | awk '{print $2}')
  echo "Mesh IP: $WG_IP"
else
  echo "WireGuard: DOWN — attempting reconnect..."
  sudo wg-quick down wg0 2>/dev/null
  sudo wg-quick up ~/.dcp/wg0.conf 2>/dev/null || sudo wg-quick up /etc/wireguard/wg0.conf 2>/dev/null
  sleep 2
  ping -c 1 -W 3 10.8.0.1 > /dev/null 2>&1 && echo "WireGuard: RECOVERED" || echo "WireGuard: STILL DOWN"
fi
```

### Step 6: Check disk space
```bash
DISK_PCT=$(df -h / | awk 'NR==2{print $5}' | tr -d '%')
echo "Disk usage: ${DISK_PCT}%"
if [ "$DISK_PCT" -gt 90 ]; then
  echo "WARNING: Disk >90% full — trigger log rotation and model cleanup"
fi
```

### Step 7: Verify backend connectivity
```bash
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" https://api.dcp.sa/health)
echo "Backend: $HTTP_CODE"
if [ "$HTTP_CODE" != "200" ]; then
  echo "WARNING: Cannot reach DCP backend"
fi
```

### Step 8: Test inference
```bash
# Generate 1 token to verify inference pipeline works
FIRST_MODEL=$(curl -s http://localhost:11434/api/tags | python3 -c "import sys,json;m=json.load(sys.stdin).get('models',[]);print(m[0]['name'] if m else '')")
if [ -n "$FIRST_MODEL" ]; then
  RESULT=$(curl -s -X POST http://localhost:11434/api/generate -d "{\"model\":\"$FIRST_MODEL\",\"prompt\":\"hi\",\"stream\":false}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
tps=d.get('eval_count',0)/max(d.get('eval_duration',1),1)*1e9
print(f'{tps:.0f} tok/s')
" 2>/dev/null)
  echo "Inference test: $FIRST_MODEL @ $RESULT"
else
  echo "Inference test: SKIPPED (no models)"
fi
```

### Step 9: Send heartbeat
```bash
curl -s -X POST https://api.dcp.sa/api/providers/heartbeat \
  -H "Authorization: Bearer $DCP_PROVIDER_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"status\": \"online\",
    \"daemon_version\": \"agent-1.0.0\",
    \"gpu_model\": \"$GPU_MODEL\",
    \"gpu_vram_total_mb\": $GPU_VRAM,
    \"gpu_temp_c\": ${GPU_TEMP:-0},
    \"models_available\": $(curl -s http://localhost:11434/api/tags | python3 -c "import sys,json;print(json.dumps([m['name'] for m in json.load(sys.stdin).get('models',[])]))" 2>/dev/null || echo '[]'),
    \"accepting_jobs\": true
  }"
```

### Step 10: Start cron watchdogs
After all checks pass, ensure all scheduled cron jobs are active:
- `dcp-heartbeat`: every 30s
- `dcp-gpu-monitor`: every 60s
- `dcp-wireguard-watchdog`: every 2min
- `dcp-ollama-watchdog`: every 2min
- `dcp-earnings-cache`: every 15min
- `dcp-self-update`: every 6h
- `dcp-log-rotate`: every 24h

### Step 11: Report
```
DCP Agent online.
  GPU: NVIDIA GeForce RTX 3060 Ti (8GB)
  Models: qwen3:4b, mistral:7b (2 loaded)
  WireGuard: connected (10.8.0.3)
  Inference: 91 tok/s
  Disk: 45% used
  Status: READY
```
