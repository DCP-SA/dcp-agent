# DCP Agent Technical Specification

**Version**: 1.0.0
**Date**: 2026-05-06
**Status**: Built, deployed, operational on dev machine

---

## 1. What is DCP Agent?

DCP Agent is an autonomous AI that runs on every provider PC in the DCP (Decentralized Compute Platform) network. It replaces the old Python daemon with a self-managing, self-healing, always-on agent.

Built as a fork of [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research, rebranded and extended with 19 DCP-specific skills, 10 cron scripts, and a custom SOUL (identity/behavior directive).

**The agent's job**: Keep the machine earning. Manage GPU inference, WireGuard networking, and self-healing so the provider never has to think about it.

---

## 2. Architecture

```
Provider PC
+-------------------------------------------------+
|  DCP Agent (Hermes fork)                        |
|  +-------------------------------------------+  |
|  | SOUL.md (identity + behavior directives)  |  |
|  +-------------------------------------------+  |
|  | 19 Skills (markdown-driven LLM guidance)  |  |
|  +-------------------------------------------+  |
|  | 10 Cron Scripts (bash, scheduled)         |  |
|  +-------------------------------------------+  |
|  | Hermes Gateway (always-on daemon)         |  |
|  +-------------------------------------------+  |
|         |              |             |           |
|    [Ollama]     [WireGuard]    [GPU/System]      |
|   :11434        wg0 mesh       nvidia-smi        |
+---------+------------+-----------+---------------+
          |            |           |
          v            v           v
  DCP Backend    VPS Gateway    MiniMax
  api.dcp.sa     10.8.0.1      (Agent brain)
  (heartbeat,    (WireGuard     api.dcp.sa/api/
   earnings,      server)       agent/gateway
   jobs)
```

### Components

| Component | What | Where |
|-----------|------|-------|
| **DCP Agent** | Hermes fork + DCP skills | `~/.dcp/agent/` |
| **Ollama** | Local LLM inference engine | `localhost:11434` |
| **WireGuard** | Encrypted mesh VPN tunnel | `10.8.0.0/24` |
| **Agent Gateway** | LLM proxy on backend | `api.dcp.sa/api/agent/gateway` |
| **MiniMax M2.7** | Agent's thinking brain | Via agent gateway |
| **Hermes Cron** | Built-in job scheduler | `~/.hermes/cron/jobs.json` |
| **launchd/systemd** | OS service manager | Auto-restart, boot start |

### Brain: How the Agent Thinks

The agent uses **MiniMax M2.7-highspeed** as its LLM brain, routed through the DCP backend gateway. This means:
- All agent LLM calls go through `api.dcp.sa/api/agent/gateway/chat/completions`
- The backend proxies to MiniMax (swappable to Claude, own model later)
- Nexus (DCP admin) can intercept and guide any agent's behavior
- No direct API calls to external LLMs from provider machines

---

## 3. Installation

### 3.1 macOS / Linux (one command)

```bash
curl -fsSL https://dcp.sa/agent-install.sh | bash -s -- --key YOUR_PROVIDER_KEY
```

**What this does:**
1. Creates `~/.dcp/` directory structure
2. Installs Python 3.11+ (brew on macOS, apt on Linux)
3. Installs `uv` (fast Python package manager)
4. Clones `dcp-agent` repo into `~/.dcp/agent/`
5. Creates Python venv, installs dependencies
6. Writes `.env` (MiniMax API key, Telegram bot token, DCP provider key)
7. Writes `~/.hermes/config.yaml` (model, yolo mode, command allowlist)
8. **One-time sudo setup**: Creates `/etc/sudoers.d/dcp-agent` for passwordless WireGuard, GPU, and network commands
9. Creates launcher script at `~/.dcp/start-agent.sh`
10. **macOS**: Installs launchd service (`sa.dcp.agent.plist`) with RunAtLoad + KeepAlive
11. **Linux**: Installs systemd user service with Restart=always
12. Starts the agent immediately

**After install, provider sees:**
```
=== DCP Agent installed ===
Chat:     cd ~/.dcp/agent && source .venv/bin/activate && hermes chat --yolo
Status:   hermes status
Telegram: message @NexusDatacenter_bot
Logs:     cat ~/.dcp/agent.log
```

### 3.2 Windows (PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Key YOUR_PROVIDER_KEY
```

**What this does:**
1. Creates `%LOCALAPPDATA%\dcp-agent\` directory
2. Installs Python 3.11 via winget
3. Installs `uv`
4. Clones repo, creates venv, installs deps
5. Writes `.env` and config
6. Configures Windows Firewall (allow WireGuard mesh + Ollama from mesh)
7. Sets Ollama env vars permanently (`OLLAMA_HOST=0.0.0.0`, `OLLAMA_KEEP_ALIVE=-1`)
8. Creates Windows Scheduled Task (runs at logon, hidden window)
9. Starts immediately

### 3.3 What the provider needs before install

- A DCP provider key (from `https://dcp.sa/setup` wizard)
- A GPU (NVIDIA recommended, Apple Silicon supported, AMD ROCm experimental)
- Ollama installed (agent will manage it, but it must be present)
- Internet access
- 10+ GB free disk space

---

## 4. Boot Sequence

Every time the agent starts (reboot, service restart, crash recovery), it runs an 11-step pre-flight check:

| Step | Check | On Failure |
|------|-------|------------|
| 1 | Detect platform (macOS/Linux/Windows) | — |
| 2 | Detect GPU (NVIDIA/Apple Silicon/AMD) | Mark as `no_gpu`, don't serve inference |
| 3 | Check Ollama running | Start with `OLLAMA_HOST=0.0.0.0 OLLAMA_KEEP_ALIVE=-1` |
| 4 | Check models loaded | Trigger model-auto-select skill |
| 5 | Check WireGuard tunnel | Reconnect from `~/.dcp/wg0.conf` |
| 6 | Check disk space | Trigger log rotation if >90% |
| 7 | Verify backend connectivity | Log warning, retry |
| 8 | Test inference (1 token) | Report degraded |
| 9 | Send heartbeat | — |
| 10 | Start all cron watchdogs | — |
| 11 | Report ready | "DCP Agent online. [GPU] ready, [N] models, tunnel [status]" |

---

## 5. Always-On Behavior Loop

The agent **never sleeps**. When not serving inference, it cycles through a priority queue:

### P0 — Every 30 seconds
- **Heartbeat**: POST status to `api.dcp.sa/api/providers/heartbeat`
- **Job poll**: Check if backend has queued jobs

### P1 — Every 60-120 seconds
- **GPU thermal**: Alert if >80C, throttle if >90C
- **Ollama health**: Process alive? API responding? Models in VRAM?
- **WireGuard health**: Ping 10.8.0.1, auto-reconnect on failure
- **Memory pressure**: Check RAM, alert if >90%

### P2 — Every 15 minutes
- **Earnings update**: Refresh local cache from backend
- **Model warm check**: Are models still in VRAM?
- **Speed benchmark**: Quick 10-token inference for tok/s tracking
- **Latency check**: RTT to DCP gateway

### P3 — Every 6 hours
- **Self-update**: `git pull`, reinstall deps if changed, restart if core changed
- **Ollama update check**: Report available updates
- **Model catalog sync**: Check if backend recommends different models
- **Disk cleanup**: Remove old logs, clean /tmp, check Ollama cache

### P4 — Daily
- **Log rotation**: Compress >24h, delete >7d, emergency cleanup if >95% disk
- **Earnings report**: Daily summary to provider (8am AST)
- **Health report**: Uptime, avg temp, avg tok/s, jobs served, errors
- **Security audit**: Verify firewall, check no public Ollama exposure

---

## 6. Skills Reference (19 total)

### Core Operations

| Skill | File | Purpose |
|-------|------|---------|
| `dcp-heartbeat` | `skills/dcp/heartbeat/SKILL.md` | 30s heartbeat to backend with GPU, models, WG status |
| `dcp-gpu-monitor` | `skills/dcp/gpu-monitor/SKILL.md` | Temperature, VRAM, utilization monitoring with thresholds |
| `dcp-ollama-manager` | `skills/dcp/ollama-manager/SKILL.md` | Start/stop Ollama, model lifecycle, health checks |
| `dcp-wireguard-health` | `skills/dcp/wireguard-health/SKILL.md` | Tunnel monitoring, auto-reconnect, handshake verification |

### Setup & Registration

| Skill | File | Purpose |
|-------|------|---------|
| `dcp-boot-sequence` | `skills/dcp/boot-sequence/SKILL.md` | 11-step pre-flight checklist on every startup |
| `dcp-first-run-setup` | `skills/dcp/first-run-setup/SKILL.md` | One-time admin/sudo grant (macOS, Linux, Windows) |
| `dcp-provider-registration` | `skills/dcp/provider-registration/SKILL.md` | Backend registration, WireGuard config fetch, tunnel setup |
| `dcp-model-auto-select` | `skills/dcp/model-auto-select/SKILL.md` | VRAM detection, tier-based model selection, pull & verify |

### Autonomous Behavior

| Skill | File | Purpose |
|-------|------|---------|
| `dcp-always-on` | `skills/dcp/always-on/SKILL.md` | Never-idle priority queue, state tracking in agent-state.json |
| `dcp-self-heal` | `skills/dcp/self-heal/SKILL.md` | Auto-fix Ollama, WireGuard, models, disk, heartbeat failures |
| `dcp-self-update` | `skills/dcp/self-update/SKILL.md` | Git pull, dep reinstall, clean restart, rollback on failure |
| `dcp-job-dispatch` | `skills/dcp/job-dispatch/SKILL.md` | Inference monitoring, readiness checks, token metering |
| `dcp-cron-orchestrator` | `skills/dcp/cron-orchestrator/SKILL.md` | Master schedule, escalation chains, failure tracking |

### Provider-Facing

| Skill | File | Purpose |
|-------|------|---------|
| `dcp-provider-chat` | `skills/dcp/provider-chat/SKILL.md` | EN+AR chat: earnings, status, help, tips, pause/resume |
| `dcp-earnings` | `skills/dcp/earnings/SKILL.md` | Query earnings API, display in SAR, projections, tips |

### Infrastructure

| Skill | File | Purpose |
|-------|------|---------|
| `dcp-network-diagnostics` | `skills/dcp/network-diagnostics/SKILL.md` | DNS, firewall, MTU, latency, traceroute, ISP, port checks |
| `dcp-power-management` | `skills/dcp/power-management/SKILL.md` | Prevent sleep (caffeinate/systemd), wake recovery |
| `dcp-log-manager` | `skills/dcp/log-manager/SKILL.md` | Log rotation, compression, emergency disk cleanup |
| `dcp-security-hardening` | `skills/dcp/security-hardening/SKILL.md` | Firewall lockdown, exposure audit, key protection |

---

## 7. Model Auto-Selection by VRAM

The agent detects GPU VRAM and automatically picks the best-earning models:

| VRAM | Primary Model | Secondary | Total VRAM Used |
|------|--------------|-----------|-----------------|
| 4-6 GB | qwen3:4b (2.5GB) | phi4-mini:3.8b (2.3GB) | ~4.8GB |
| 8 GB | qwen3:8b (4.9GB) | qwen3:4b (2.5GB) | ~7.4GB |
| 12 GB | qwen3:14b (8.7GB) | qwen3:4b (2.5GB) | ~11.2GB |
| 16 GB | qwen3:14b (8.7GB) | qwen3:8b (4.9GB) | ~13.6GB |
| 24 GB | qwen3:32b (19.8GB) | qwen3:4b (2.5GB) | ~22.3GB |
| 32+ GB | qwen3:32b (19.8GB) | qwen3:14b (8.7GB) | ~28.5GB |

**Rule**: Bigger models = more earnings per token. Always fill VRAM (minus 500MB headroom).

---

## 8. Inference Flow

```
Renter API call
    |
    v
POST api.dcp.sa/v1/chat/completions
    |
    v
Backend selects provider (model match, latency, load, online)
    |
    v
Proxy to http://{provider_wg_ip}:11434/v1/chat/completions
    |
    v
Ollama serves inference (streaming SSE)
    |
    v
Backend logs job (tokens, duration, provider, renter)
    |
    v
Provider earns SAR
```

The agent does NOT intercept inference — Ollama handles it directly via WireGuard mesh. The agent monitors readiness, tracks jobs, and ensures the machine is always ready.

---

## 9. Self-Healing & Escalation

When something breaks, the agent follows this chain:

```
Failure detected
    |
    v
[Self-fix] (restart service, reconnect tunnel, re-pull model)
    |--- Fixed? --> Log, continue
    |
    v
[Retry x3] (10s, 30s, 60s backoff)
    |--- Fixed? --> Log, continue
    |
    v
[Full diagnostics] (DNS, firewall, MTU, traceroute)
    |--- Fixed? --> Log, continue
    |
    v
[Upload diagnostics] POST api.dcp.sa/api/providers/install-error
    |
    v
[Notify provider] "I couldn't fix [X]. Here's what I tried..."
    |
    v
[Mark degraded] heartbeat: {"status": "degraded", "issue": "..."}
```

**Failure tracking**: `~/.dcp/failure-tracker.json` tracks consecutive failures and 24h totals per subsystem (ollama, wireguard, heartbeat, gpu). Counters reset on success. 24h counters reset at midnight.

---

## 10. Security

### Ollama Lockdown
- Ollama binds on `0.0.0.0:11434` (required for WireGuard mesh access)
- Firewall rules block ALL public access to port 11434
- Only `10.8.0.0/24` (WireGuard mesh) and `127.0.0.1` (localhost) can reach Ollama
- Platform-specific: macOS uses pf anchors, Linux uses iptables, Windows uses NetFirewallRule

### Key Protection
- `.env` and `wg0.conf` stored with `chmod 600`
- Provider key never logged in full — masked to first 20 chars
- Daily audit scans logs for leaked keys, auto-redacts if found

### Exposure Check
- Daily: curl public IP on port 11434 — if reachable, emergency firewall re-apply
- Verify no unexpected listeners
- Check sudoers file integrity

---

## 11. Provider Communication

### Channels
- **Telegram**: Via @NexusDatacenter_bot (Hermes gateway)
- **Local CLI**: `hermes chat --yolo` in the agent directory

### Language
- Auto-detects Arabic (Unicode \u0600-\u06FF) and responds in Arabic
- Default: English
- All monetary values in SAR (Saudi Riyal)
- All times in AST (Arabia Standard Time, UTC+3)

### What providers can ask
- "How much did I earn?" / "كم كسبت؟" — earnings breakdown
- "What's my status?" / "ما حالة جهازي؟" — GPU, models, tunnel, uptime
- "Why am I offline?" / "ليش أنا أوفلاين؟" — run diagnostics, report findings
- "How do I earn more?" / "كيف أكسب أكثر؟" — context-aware tips
- "Restart everything" / "أعد تشغيل كل شيء" — full service restart
- "Stop" / "أوقف" — pause jobs, stay online for monitoring
- "Resume" / "استمر" — resume accepting jobs

---

## 12. File Structure

```
~/.dcp/
  agent/                    # Git clone of dcp-agent
    SOUL.md                 # Agent identity & behavior directives
    skills/dcp/             # 19 skill directories
    scripts/                # 10 cron scripts
    hermes_cli/             # Modified Hermes CLI (DCP-branded)
    install.sh              # macOS/Linux installer
    install.ps1             # Windows installer
    .env                    # API keys, provider key
  agent-initialized         # First-run flag
  agent-state.json          # Runtime state (status, jobs, earnings, temp)
  earnings-cache.json       # Cached earnings from backend
  failure-tracker.json      # Consecutive/24h failure counts
  wg0.conf                  # WireGuard config (chmod 600)
  start-agent.sh            # Launcher script
  last-check-ts             # Timestamp for sleep/wake detection
  registration.json         # Registration state
  logs/
    ollama.log              # Ollama output
    heartbeat.log           # Heartbeat results
    gpu.log                 # GPU thermal events
    memory.log              # Memory/disk warnings
    update.log              # Self-update activity
    security.log            # Security audit results
    watchdog-wg.log         # WireGuard watchdog
    watchdog-ollama.log     # Ollama watchdog
    wake.log                # Sleep/wake recovery
    archive/                # Compressed old logs
  scripts/                  # On-wake recovery scripts
```

---

## 13. Backend Integration Points

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `api.dcp.sa/api/providers/heartbeat` | POST | Status, GPU, models, WG mesh IP |
| `api.dcp.sa/api/providers/earnings/summary` | GET | Earnings breakdown |
| `api.dcp.sa/api/providers/wg/register` | POST | Get WireGuard peer config |
| `api.dcp.sa/api/providers/install-error` | POST | Upload diagnostics |
| `api.dcp.sa/api/providers/connectivity-check` | POST | Verify inference reachability |
| `api.dcp.sa/api/agent/gateway/chat/completions` | POST | Agent LLM brain (MiniMax) |
| `api.dcp.sa/api/agent/gateway/health` | GET | Gateway health check |
| `api.dcp.sa/v1/provider/me` | GET | Provider info / key validation |
| `api.dcp.sa/health` | GET | Backend health check |

---

## 14. Platform-Specific Notes

### macOS
- Service: launchd plist at `~/Library/LaunchAgents/sa.dcp.agent.plist`
- Sleep prevention: `caffeinate -dis` + `pmset` settings
- GPU: Apple Silicon via `system_profiler` + `powermetrics`
- WireGuard: `wg-quick` via Homebrew, utun interface
- Sudoers: WireGuard, powermetrics, networksetup, ifconfig

### Linux
- Service: systemd user unit at `~/.config/systemd/user/dcp-agent.service`
- Sleep prevention: `systemctl mask sleep.target` + logind.conf
- GPU: NVIDIA via `nvidia-smi`, AMD via `rocm-smi`
- WireGuard: `wg-quick`, wg0 interface
- Sudoers: WireGuard, nvidia-smi, systemctl restart ollama/wg-quick

### Windows
- Service: Windows Scheduled Task (runs at logon, hidden)
- Sleep prevention: `powercfg` high-performance plan
- GPU: NVIDIA via `nvidia-smi`, env vars set permanently
- WireGuard: `wireguard /installtunnelservice`
- Firewall: `New-NetFirewallRule` for mesh + Ollama

---

## 15. What Happens When...

### Provider turns on their PC
1. OS starts DCP Agent service (launchd/systemd/scheduled task)
2. Agent runs boot sequence (11 steps)
3. Ollama starts, models load into VRAM
4. WireGuard tunnel connects
5. Heartbeat sent, backend marks provider online
6. Agent starts accepting jobs
7. Provider earns SAR for every inference served

### Internet drops
1. Heartbeat fails (detected in 30s)
2. WireGuard watchdog detects tunnel down (2min)
3. Agent keeps trying to reconnect every 2min
4. After 3 failures, runs full network diagnostics
5. When internet returns, WireGuard auto-reconnects
6. Heartbeat resumes, backend marks provider online again

### Ollama crashes
1. Ollama watchdog detects within 2min
2. Kills any zombie process, restarts with correct env vars
3. Waits 5s, verifies API responds
4. Re-warms models in VRAM
5. If still down after 3 tries, uploads diagnostics

### GPU overheats (>90C)
1. GPU monitor detects in 60s
2. Logs CRITICAL warning
3. NVIDIA driver self-throttles (agent logs this)
4. When temp drops, normal operations resume
5. If persistent, alerts provider: "Check your cooling"

### Provider closes laptop lid
1. macOS: caffeinate prevents sleep (if configured)
2. If machine sleeps anyway, on wake:
   - Detects time gap >2min in always-on loop
   - Runs wake recovery script
   - Waits for network, reconnects WireGuard
   - Restarts Ollama if needed, re-warms models
   - Sends heartbeat with "wake_recovery" event

### Disk fills up
1. Memory check detects >90% disk (every 2min)
2. Triggers disk cleanup: rotate logs, clean archives, purge /tmp
3. If >95%: emergency cleanup, remove compressed archives, report to backend
4. If models need to be removed, removes smallest/least-used first

### Provider key becomes invalid
1. Heartbeat returns 401
2. Self-heal checks: `GET api.dcp.sa/v1/provider/me`
3. If auth fails, alerts provider: "Your provider key is no longer valid"
4. Agent pauses job acceptance but keeps monitoring
5. Provider needs to re-register via dcp.sa/setup

### Agent update available
1. Self-update checks every 6h (`git fetch`, compare HEAD)
2. Waits until no active inference
3. `git pull --ff-only`
4. If dependencies changed: reinstall via uv/pip
5. If core code changed: exit non-zero (service manager restarts)
6. If update breaks things: `git reset --hard HEAD~1` rollback

### New model released
1. Model catalog sync checks every 6h
2. Backend can push recommended models for this GPU tier
3. Agent compares VRAM capacity, pulls new model if it fits
4. Removes old model if needed to make room
5. Registers new model list with backend

---

## 16. Roadmap

### Done (Phase 1-3)
- [x] Hermes fork cloned and configured
- [x] 19 DCP skills written
- [x] 10 cron scripts created
- [x] SOUL.md (agent identity)
- [x] default_soul.py wired to load SOUL.md
- [x] Cross-platform installers (macOS, Linux, Windows)
- [x] Backend agent gateway (MiniMax proxy) deployed
- [x] Hermes gateway running as daemon
- [x] Watchdog cron jobs active
- [x] Agent memory loaded with all skills
- [x] Live test: inference sent to provider

### Next (Phase 4)
- [ ] Tauri desktop app integration (installer launches agent)
- [ ] Full rebrand: CLI banner, README, package name
- [ ] Backend: all API endpoints for registration, earnings, connectivity
- [ ] Provider onboarding wizard via Telegram
- [ ] Multi-provider testing (Fadi + 2 more)
- [ ] Own model training on DCP hardware (replace MiniMax)
