---
name: dcp-heartbeat
description: "Send provider heartbeat to DCP backend — replaces the Python daemon."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, heartbeat, daemon, provider, backend]
---

# DCP Heartbeat

Send regular heartbeats to the DCP backend so the platform knows this provider is alive and available.

## What this skill does

Replaces the Python daemon's heartbeat function. Every 30 seconds, reports:
- Provider status (online/offline/paused)
- GPU info (model, temperature, VRAM, utilization)
- Models available (from Ollama)
- Network status (WireGuard connected, latency)
- Daemon version
- Accepting jobs status

## Heartbeat endpoint
```bash
curl -s -X POST https://api.dcp.sa/api/providers/heartbeat \
  -H "Authorization: Bearer $DCP_PROVIDER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "status": "online",
    "daemon_version": "agent-1.0.0",
    "gpu_model": "NVIDIA GeForce RTX 3060 Ti",
    "gpu_temp_c": 54,
    "gpu_vram_used_mb": 2500,
    "gpu_vram_total_mb": 8192,
    "gpu_utilization_pct": 30,
    "models_available": ["qwen3:4b", "mistral:7b"],
    "wg_mesh_ip": "10.8.0.2",
    "accepting_jobs": true,
    "uptime_seconds": 3600
  }'
```

## Collecting heartbeat data

### GPU info
- NVIDIA: `nvidia-smi --query-gpu=name,temperature.gpu,memory.used,memory.total,utilization.gpu --format=csv,noheader`
- Apple Silicon: `system_profiler SPDisplaysDataType`

### Models
```bash
curl -s http://localhost:11434/api/tags | python3 -c "import sys,json;print([m['name'] for m in json.load(sys.stdin)['models']])"
```

### WireGuard
```bash
# Get mesh IP
ip addr show wg0 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1
```

## Cron schedule
Every 30 seconds. If heartbeat fails 3 times consecutively, attempt self-heal (restart WG, restart Ollama).
