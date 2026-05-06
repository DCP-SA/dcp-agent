---
name: dcp-ollama-manager
description: "Manage Ollama inference engine — start, stop, model lifecycle, health checks."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, ollama, inference, models, provider]
---

# DCP Ollama Manager

Manage the Ollama inference engine on the provider's machine.

## What this skill does

Ensures Ollama is running, healthy, and serving the right models for the DCP network.

## Check Ollama status
```bash
# Is Ollama running?
curl -s http://localhost:11434/ && echo "Ollama OK" || echo "Ollama DOWN"

# List loaded models
curl -s http://localhost:11434/api/tags | python3 -c "import sys,json;[print(f'{m[\"name\"]} ({m[\"size\"]/1e9:.1f}GB)') for m in json.load(sys.stdin)['models']]"

# Check which models are currently loaded in memory
curl -s http://localhost:11434/api/ps
```

## Start Ollama (if not running)

### macOS / Linux
```bash
OLLAMA_HOST=0.0.0.0 OLLAMA_KEEP_ALIVE=-1 ollama serve &
```

### Windows
```powershell
$env:OLLAMA_HOST = "0.0.0.0"; $env:OLLAMA_KEEP_ALIVE = "-1"; ollama serve
```

**Critical settings:**
- `OLLAMA_HOST=0.0.0.0` — listen on all interfaces (required for WireGuard mesh access)
- `OLLAMA_KEEP_ALIVE=-1` — keep models loaded in VRAM permanently

## Model management
```bash
# Pull a model
ollama pull qwen3:4b

# Remove a model
ollama rm mistral:7b

# Test inference
curl -s -X POST http://localhost:11434/api/generate -d '{"model":"qwen3:4b","prompt":"test","stream":false}' | python3 -c "import sys,json;d=json.load(sys.stdin);print(f'{d[\"eval_count\"]} tokens in {d[\"eval_duration\"]/1e9:.1f}s = {d[\"eval_count\"]/d[\"eval_duration\"]*1e9:.0f} tok/s')"
```

## Health check
Every 30 seconds:
1. Is the process running?
2. Does the API respond?
3. Are models loaded?
4. Can we generate a test token?

If unhealthy: restart Ollama, reload models, report to backend.
