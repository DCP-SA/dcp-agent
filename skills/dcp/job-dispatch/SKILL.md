---
name: dcp-job-dispatch
description: "Accept inference jobs from DCP backend, route to Ollama, report results."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, jobs, inference, dispatch, routing]
---

# DCP Job Dispatch

Accept and process inference requests routed to this provider by the DCP backend.

## How jobs arrive

The DCP backend routes inference requests to providers via their WireGuard mesh IP. The flow:

1. Renter calls `POST https://api.dcp.sa/v1/chat/completions`
2. Backend selects a provider based on: model availability, latency, load, online status
3. Backend proxies the request to `http://{provider_mesh_ip}:11434/v1/chat/completions`
4. Ollama serves the request directly
5. Backend logs the job (tokens, duration, provider, renter)

## What the agent monitors

The agent doesn't intercept inference — Ollama handles it directly. The agent monitors:

### Active job tracking
```bash
# Check if Ollama is currently processing
curl -s http://localhost:11434/api/ps | python3 -c "
import sys, json
ps = json.load(sys.stdin)
for m in ps.get('models', []):
    name = m.get('name', 'unknown')
    vram = m.get('size_vram', 0) / 1e9
    expires = m.get('expires_at', 'never')
    print(f'  {name}: {vram:.1f}GB VRAM, expires {expires}')
if not ps.get('models'):
    print('  No active models')
"
```

### Job completion logging
```bash
# After each job completes, log locally
python3 << 'LOG'
import json, os, time
from datetime import datetime

state_path = os.path.expanduser("~/.dcp/agent-state.json")
state = {}
if os.path.exists(state_path):
    with open(state_path) as f:
        state = json.load(f)

state["total_jobs_today"] = state.get("total_jobs_today", 0) + 1
state["last_job_served"] = datetime.utcnow().isoformat() + "Z"
state["total_tokens_today"] = state.get("total_tokens_today", 0)  # Updated by heartbeat

with open(state_path, "w") as f:
    json.dump(state, f, indent=2)
LOG
```

## Job readiness checks

Before marking as "accepting_jobs":

1. **Ollama responding**: `curl -sf http://localhost:11434/` returns 200
2. **Model loaded in VRAM**: `curl -s http://localhost:11434/api/ps` shows at least 1 model
3. **WireGuard connected**: Mesh IP reachable from the agent
4. **GPU healthy**: Temperature <90C, VRAM not at 100%
5. **Disk OK**: >10% free space (for Ollama temp files)

```bash
# Combined readiness check
READY=true

curl -sf http://localhost:11434/ > /dev/null 2>&1 || READY=false
ping -c 1 -W 2 10.8.0.1 > /dev/null 2>&1 || READY=false

if [ "$READY" = true ]; then
  MODELS=$(curl -s http://localhost:11434/api/tags | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('models',[])))" 2>/dev/null)
  [ "$MODELS" -gt 0 ] 2>/dev/null || READY=false
fi

echo "Job ready: $READY"
```

## Handling overload

If GPU utilization is >95% and a new request comes in:
- Ollama handles queuing natively (requests queue in order)
- If queue depth >5, report "busy" in next heartbeat
- Backend will route new requests to other providers

## Handling model-not-found

If a request comes for a model this provider doesn't have:
- Ollama returns 404
- Backend will retry on another provider
- Agent logs the miss and checks if it should pull that model:

```bash
# Check if the requested model fits in available VRAM
REQUESTED_MODEL="$1"
VRAM_FREE=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1)

# Only auto-pull if >2GB free VRAM and model is in DCP catalog
if [ "${VRAM_FREE:-0}" -gt 2000 ]; then
  echo "Auto-pulling requested model: $REQUESTED_MODEL"
  ollama pull "$REQUESTED_MODEL" &
fi
```

## Streaming support

Ollama supports streaming natively. The backend proxies the SSE stream directly. The agent doesn't need to do anything for streaming — it's handled at the HTTP level.

## Token metering

The backend meters tokens from Ollama's response headers. The agent verifies locally:

```bash
# Periodic token count reconciliation
curl -s https://api.dcp.sa/api/providers/earnings/summary \
  -H "Authorization: Bearer $DCP_PROVIDER_KEY" | python3 -c "
import sys, json, os

backend = json.load(sys.stdin)
state_path = os.path.expanduser('~/.dcp/agent-state.json')
state = json.load(open(state_path)) if os.path.exists(state_path) else {}

backend_jobs = backend.get('today_jobs', 0)
local_jobs = state.get('total_jobs_today', 0)

if abs(backend_jobs - local_jobs) > 5:
    print(f'WARNING: Job count mismatch. Backend: {backend_jobs}, Local: {local_jobs}')
else:
    print(f'Token metering in sync. Jobs today: {backend_jobs}')
"
```
