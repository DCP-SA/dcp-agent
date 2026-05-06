---
name: dcp-cron-orchestrator
description: "Master schedule config — all watchdogs, intervals, dependencies, escalation."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, cron, schedule, orchestrator, watchdog, master]
---

# DCP Cron Orchestrator

Master configuration for all agent scheduled tasks. This is the single source of truth for what runs when.

## Master schedule

| Job name | Interval | Skill | Priority | Escalation |
|----------|----------|-------|----------|------------|
| heartbeat | 30s | dcp-heartbeat | P0 | 3 fails -> self-heal |
| gpu-thermal | 60s | dcp-gpu-monitor | P1 | >90C -> throttle |
| ollama-watchdog | 2min | dcp-ollama-manager | P1 | restart, 3 fails -> reinstall |
| wireguard-watchdog | 2min | dcp-wireguard-health | P1 | reconnect, 3 fails -> re-register |
| memory-check | 2min | dcp-self-heal | P1 | kill leak, report |
| earnings-cache | 15min | dcp-earnings | P2 | silent fail OK |
| model-warm | 15min | dcp-ollama-manager | P2 | re-load if evicted |
| speed-bench | 15min | dcp-boot-sequence | P2 | log only |
| latency-check | 15min | dcp-network-diagnostics | P2 | >200ms -> warn |
| self-update | 6h | dcp-self-update | P3 | defer if busy |
| model-catalog | 6h | dcp-model-auto-select | P3 | pull if new |
| disk-cleanup | 6h | dcp-log-manager | P3 | emergency if >95% |
| log-rotation | 24h (3am) | dcp-log-manager | P4 | compress + delete |
| earnings-report | 24h (8am) | dcp-earnings | P4 | message provider |
| health-report | 24h (8am) | dcp-always-on | P4 | message provider |
| security-audit | 24h (4am) | dcp-security-hardening | P4 | alert if exposed |

## Hermes cron registration

```bash
# Register all jobs via hermes cron command
# Run this on first boot or after agent update

hermes cron add --name "dcp-heartbeat" \
  --schedule "*/30 * * * * *" \
  --command "bash ~/.dcp/scripts/heartbeat.sh"

hermes cron add --name "dcp-gpu-thermal" \
  --schedule "* * * * *" \
  --command "bash ~/.dcp/scripts/gpu-check.sh"

hermes cron add --name "dcp-ollama-watchdog" \
  --schedule "*/2 * * * *" \
  --command "bash ~/.dcp/scripts/ollama-watchdog.sh"

hermes cron add --name "dcp-wireguard-watchdog" \
  --schedule "*/2 * * * *" \
  --command "bash ~/.dcp/scripts/wireguard-watchdog.sh"

hermes cron add --name "dcp-memory-check" \
  --schedule "*/2 * * * *" \
  --command "bash ~/.dcp/scripts/memory-check.sh"

hermes cron add --name "dcp-earnings-cache" \
  --schedule "*/15 * * * *" \
  --command "bash ~/.dcp/scripts/earnings-update.sh"

hermes cron add --name "dcp-self-update" \
  --schedule "0 */6 * * *" \
  --command "bash ~/.dcp/scripts/self-update.sh"

hermes cron add --name "dcp-disk-cleanup" \
  --schedule "0 */6 * * *" \
  --command "bash ~/.dcp/scripts/disk-cleanup.sh"

hermes cron add --name "dcp-log-rotation" \
  --schedule "0 0 * * *" \
  --command "bash ~/.dcp/scripts/log-rotate.sh"

hermes cron add --name "dcp-security-audit" \
  --schedule "0 1 * * *" \
  --command "bash ~/.dcp/scripts/security-audit.sh"

hermes cron add --name "dcp-daily-report" \
  --schedule "0 5 * * *" \
  --command "bash ~/.dcp/scripts/daily-report.sh"
```

## Escalation chain

When a cron job detects a failure:

```
Failure detected
    |
    v
[Attempt self-fix] (skill-specific)
    |
    +--> Fixed? -> Log, continue
    |
    v
[Retry x3 with backoff] (10s, 30s, 60s)
    |
    +--> Fixed? -> Log, continue
    |
    v
[Run full diagnostics] (dcp-network-diagnostics)
    |
    +--> Fixed? -> Log, continue
    |
    v
[Upload diagnostics to backend]
    POST https://api.dcp.sa/api/providers/install-error
    |
    v
[Notify provider via chat]
    "I couldn't fix [X]. Here's what I tried: ..."
    |
    v
[Mark as degraded in heartbeat]
    {"status": "degraded", "issue": "..."}
```

## Failure tracking

```bash
# ~/.dcp/failure-tracker.json
{
  "ollama": {"consecutive_fails": 0, "last_fail": null, "total_fails_24h": 0},
  "wireguard": {"consecutive_fails": 0, "last_fail": null, "total_fails_24h": 0},
  "heartbeat": {"consecutive_fails": 0, "last_fail": null, "total_fails_24h": 0},
  "gpu": {"consecutive_fails": 0, "last_fail": null, "total_fails_24h": 0}
}
```

Update after each cron run. Reset consecutive counter on success. Reset 24h counter at midnight.

## Cron conflict prevention

- Never run two heavy operations at the same time (e.g., model pull + self-update)
- Use a lockfile at `~/.dcp/cron.lock` for exclusive operations
- Heartbeat and health checks always run, even during heavy operations

```bash
# Lockfile pattern for exclusive operations
LOCKFILE="$HOME/.dcp/cron.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "Another heavy operation running, skipping"; exit 0; }

# ... do heavy work ...

# Lock auto-releases when script exits
```

## Monitoring the monitor

If the cron system itself dies:
- The launchd/systemd service restarts the Hermes gateway (KeepAlive/Restart=always)
- Gateway restart re-registers all cron jobs
- If gateway can't start, the service manager retries every 10 seconds
- Last resort: the daily cron at OS level (`crontab`) checks if the agent process is alive

```bash
# Backup crontab entry (installed by install.sh)
# Checks every 5 minutes if the agent is running, restarts if not
# */5 * * * * pgrep -f "hermes gateway" > /dev/null || bash ~/.dcp/start-agent.sh
```
