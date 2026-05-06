---
name: dcp-always-on
description: "Idle behavior loop — the agent never sleeps, always has a next action."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, idle, loop, autonomous, always-on]
---

# DCP Always-On Loop

When not actively serving an inference job or responding to the provider, cycle through these actions continuously.

## Priority queue (highest first)

### P0 — Immediate (every 30s)
1. **Heartbeat** — POST to backend, confirm online status
2. **Job poll** — check if backend has queued jobs for this provider

### P1 — Health (every 60-120s)
3. **GPU thermal check** — if temp >80C, log warning; >90C reduce load
4. **Ollama process check** — is the API responding? Are models loaded in VRAM?
5. **WireGuard tunnel check** — can we reach 10.8.0.1?
6. **Memory pressure** — if system RAM >90%, check for leaks

### P2 — Optimization (every 15min)
7. **Earnings update** — refresh earnings cache from backend
8. **Model warm check** — are models still loaded in VRAM or did Ollama evict them?
9. **Speed benchmark** — run a quick 10-token inference to track tok/s over time
10. **Latency check** — measure RTT to DCP gateway, log if >200ms

### P3 — Maintenance (every 6h)
11. **Self-update** — git pull, check if dependencies changed
12. **Ollama update** — check for new Ollama version
13. **Model catalog sync** — check if backend recommends different models for this GPU
14. **Disk cleanup** — remove old logs, check /tmp, check Ollama cache

### P4 — Daily (every 24h)
15. **Log rotation** — compress logs older than 24h, delete logs older than 7 days
16. **Earnings report** — generate daily earnings summary for provider
17. **Health report** — uptime, avg temp, avg tok/s, jobs served, errors encountered
18. **Security audit** — verify firewall rules, check no unexpected listeners

## How to cycle

```python
# Pseudocode — the cron system handles actual scheduling
SCHEDULE = {
    "heartbeat":        "*/30 * * * * *",   # every 30s
    "job_poll":         "*/30 * * * * *",   # every 30s
    "gpu_thermal":      "*/60 * * * * *",   # every 60s
    "ollama_health":    "*/120 * * * * *",  # every 2min
    "wg_health":        "*/120 * * * * *",  # every 2min
    "memory_check":     "*/120 * * * * *",  # every 2min
    "earnings_update":  "*/15 * * * *",     # every 15min
    "model_warm":       "*/15 * * * *",     # every 15min
    "speed_bench":      "*/15 * * * *",     # every 15min
    "latency_check":    "*/15 * * * *",     # every 15min
    "self_update":      "0 */6 * * *",      # every 6h
    "ollama_update":    "0 */6 * * *",      # every 6h
    "model_catalog":    "0 */6 * * *",      # every 6h
    "disk_cleanup":     "0 */6 * * *",      # every 6h
    "log_rotation":     "0 3 * * *",        # daily 3am
    "earnings_report":  "0 8 * * *",        # daily 8am AST
    "health_report":    "0 8 * * *",        # daily 8am AST
    "security_audit":   "0 4 * * *",        # daily 4am
}
```

## Between cycles

When all scheduled tasks are done and no jobs are queued:
- Keep models warm in VRAM (OLLAMA_KEEP_ALIVE=-1 handles this)
- Monitor for incoming chat from provider
- Monitor for incoming jobs from backend
- Do NOT run heavy benchmarks during peak hours (6pm-2am AST)

## State tracking

Maintain a local state file at `~/.dcp/agent-state.json`:
```json
{
  "status": "online",
  "last_heartbeat": "2026-05-06T12:00:00Z",
  "last_job_served": "2026-05-06T11:45:00Z",
  "last_self_update": "2026-05-06T06:00:00Z",
  "uptime_since": "2026-05-06T08:00:00Z",
  "total_jobs_today": 24,
  "total_tokens_today": 15000,
  "errors_today": 0,
  "earnings_today_halala": 1500,
  "gpu_temp_avg": 55,
  "tok_s_avg": 91,
  "models_loaded": ["qwen3:4b", "mistral:7b"]
}
```

Update this file after every significant event. The state file is the single source of truth for the agent's local understanding of itself.
