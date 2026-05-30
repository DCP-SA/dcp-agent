# DCP Agent — onboarding for first contribution

A focused, opinionated guide for new contributors to `dhnpmp-tech/dcp-agent`. Read `AGENTS.md` and `CONTRIBUTING.md` for the deep dive on the upstream Hermes Agent codebase. This file covers only what's specific to the **DCP fork** and what gets you to your first merged PR in under an hour.

---

## What this fork is

This is a fork of [Nous Research's Hermes Agent](https://github.com/NousResearch/hermes-agent) with DCP-specific deltas. The upstream Hermes is the generic engine; the DCP fork adds:

| Delta | Where |
|---|---|
| Rebrand Hermes → DCP Agent (banners, defaults, install paths) | `hermes_cli/setup.py`, `hermes_cli/banner.py`, `default_soul.py` |
| LLM brain routed through `api.dcp.sa/api/agent/gateway` (DCP gateway pattern — upstream keys stay on VPS, never on provider nodes) | `~/.hermes/.env`, set by install script |
| Auto-orchestration on first run when `install_token` is present | `hermes_cli/gateway.py` — commit `daf22f53` |
| Heartbeat executes `pull_model` tasks from backend response | commit `faf4cf9f` |
| 19 DCP-specific skills + diagnostic/maintenance cron scripts + SOUL.md persona | commits `8480a5fe`, `217e83fb` (runtime watchdogs moved to the daemon — see "Runtime topology" below) |
| Installer scripts (`scripts/install.sh`, `scripts/install-agent.sh`) hook into `api.dcp.sa/install/agent` and `https://api.dcp.sa/installers/dcp-agent.tar.gz` | `scripts/` |
| Pull-tasks loop (separate provider work surface) | `feat/agent-pull-tasks-v2` branch — in flight |

If you're touching code that's pure upstream Hermes, prefer to send the change to `NousResearch/hermes-agent` first, then merge upstream here.

---

## Runtime topology (decision A: daemon-everywhere) — READ THIS FIRST

A provider box runs **two** distinct things, with a strict division of labour:

| Layer | What it is | What it owns |
|---|---|---|
| **DCP daemon** (`dcp_daemon.py`, served by the platform) | The **runtime**. Installed first, runs as a system service. | Heartbeat, WireGuard, model-pull, engine watchdog, self-update. Exposes a local health endpoint on **`:19876`** (and a WG diag side-server on `:19877`). |
| **Hermes agent** (this repo) | An **optional brain on top**. Read-mostly diagnosis + provider chat. | Reads the daemon's `:19876` health + backend state. Runs DCP skills and a few **diagnostic/maintenance** jobs (memory-check, disk-cleanup, earnings cache, security-audit, daily-report). |

**The agent does NOT run its own heartbeat, WireGuard watchdog, model-pull loop, engine watchdog, or self-update.** The daemon owns all of those. This is the fix for the recurring **Node-2 split-brain**: before Phase 0 the agent installer *also* registered `heartbeat.sh`, `wireguard-watchdog.sh`, `ollama-watchdog.sh`, `self-update.sh`, and `agent-liveness.sh` as cron/services, so two heartbeats overwrote the same provider row every ~30s and three WireGuard self-healers fought each other.

**Install order is mandatory: daemon first, then agent.** The agent installer hard-checks that the daemon is answering on `:19876` and **refuses to install** if it isn't (you'd otherwise be left with a box that has no runtime at all). The script files for the daemon-owned watchdogs still ship in `scripts/` for reference and ad-hoc diagnosis — they're just never registered as the runtime.

```bash
# 1. Install the DCP daemon (the runtime) — do this FIRST.
curl -fsSL https://dcp.sa/install.sh | sudo bash -s -- --token <YOUR_TOKEN>

# 2. Then install the Hermes agent (the brain) on top.
curl -fsSL https://api.dcp.sa/install/agent | bash -s -- --key <YOUR_PROVIDER_KEY>
```

> Status: this is **Phase 0** of the runtime consolidation (backlog gap #6). Phase 0 stops the agent from registering the duplicate runtime scripts and adds the daemon pre-flight. **Phase 1+** repositions the agent further: wire the daemon-install directly into the agent installer (so step 1 happens automatically), have the agent *read* daemon state rather than re-derive it, give it a scoped non-provider key, and route control actions as requests to the daemon/control-API.

---

## Quick start (clone → run → first PR in <60 min)

### 1. Clone
```bash
gh repo clone dhnpmp-tech/dcp-agent
cd dcp-agent
```

### 2. Install — use the upstream installer, which provisions everything
```bash
./scripts/install.sh        # Linux / macOS / WSL2 / Termux
# OR Windows native:
# powershell -ExecutionPolicy Bypass -File scripts/install.ps1
```

The installer creates a `uv`-managed Python 3.11 venv at `~/.hermes/hermes-agent/venv` (or `.venv` in the repo root for dev). It installs `hermes`, `hermes-agent`, and `hermes-acp` CLI entries.

**Known gotcha (2026-05-13, Tareq Node 2 incident):** the installer does not currently bundle `fastapi` and `uvicorn`, which are required for the `hermes dashboard` web UI (port 8642). If `hermes dashboard --port 8642` fails with `No module named 'fastapi'`, run:
```bash
~/.dcp/agent/.venv/bin/pip install fastapi uvicorn
```
Track upstream: this should land in `pyproject.toml`'s `[project.optional-dependencies] all` or a new `dashboard` extra.

### 3. Configure for DCP
The installer writes `~/.hermes/.env`. The DCP-required keys are:
```
MINIMAX_BASE_URL=https://api.dcp.sa/api/agent/gateway   # routes brain calls through DCP
MINIMAX_API_KEY=dcp-provider-XXXXXXXX                   # your provider key as the gateway auth
DCP_PROVIDER_KEY=dcp-provider-XXXXXXXX                  # same key, used by DCP-specific skills
DCP_API_BASE=https://api.dcp.sa
HERMES_AUTO_APPROVE=1                                    # yolo mode for first-run orchestration
```

Your provider key lives in `/root/dc1-platform/backend/data/providers.db` on gate0 — pre-fetch with:
```bash
ssh root@76.13.179.86 'sqlite3 /root/dc1-platform/backend/data/providers.db \
  "SELECT name, api_key FROM providers WHERE name LIKE \"%YOUR_NAME%\";"'
```

### 4. Run
```bash
# Local dev: launch the dashboard with embedded TUI
hermes dashboard --port 8642 --host 127.0.0.1 --tui

# Or the messaging gateway (needs a platform like Telegram configured)
hermes gateway run
```

Open `http://localhost:8642` for the dashboard with embedded chat. Gateway exits if no platforms are enabled — that's expected, configure one via `hermes setup` to keep it running.

### 5. Verify
```bash
hermes status                # ✓ on Model, ✓ on at least one API key
```

---

## Tests

The full test command (matches what CI runs):
```bash
./scripts/run_tests.sh
```

It probes for `.venv`, then `venv`, then `~/.hermes/hermes-agent/venv` — so it works from a worktree or a fresh clone.

For targeted iteration on a single area:
```bash
.venv/bin/python -m pytest tests/test_specific.py -x
```

---

## Lint + format

```bash
.venv/bin/ruff check .
.venv/bin/ruff format .
.venv/bin/ty check          # type checker (config in pyproject.toml)
```

CI uses ruff in lint-only mode. Format failures don't fail CI but they will be flagged on PR review.

---

## Branch naming + PR conventions

Match the existing pattern in `git log --first-parent main`:

| Prefix | When | Example |
|---|---|---|
| `feat/` | new feature / capability | `feat/agent-pull-tasks-v2` |
| `fix/` | bugfix | `fix/dashboard-fastapi-missing` |
| `doc/` | docs-only | `doc/dcp-onboarding` |
| `chore/` | deps, ci, refactor with no behavior change | `chore/bump-uv-version` |
| `infra/` | install/deploy/packaging | `infra/installer-bundle-dashboard-deps` |

**PR template:** there isn't one currently; the convention is a 1-line "what" + a "why" paragraph in the body, plus a "test plan" checklist if behavior changed. Look at recent merged PRs (`gh pr list --state merged --limit 5`) for the shape.

**Conventional commits** are used in commit messages: `feat(scope):`, `fix(scope):`, etc. See the first-parent log.

---

## How to ship a new build (the tarball)

`api.dcp.sa/install/agent` downloads from `https://api.dcp.sa/installers/dcp-agent.tar.gz`. To update what new providers get:

1. Merge your PR to `main`.
2. Build the tarball:
   ```bash
   # from main
   tar --exclude='.git' --exclude='.venv' --exclude='__pycache__' \
       --exclude='node_modules' --exclude='.pytest_cache' \
       -czf dcp-agent.tar.gz -C .. dcp-agent
   ```
3. SCP it to gate0 at `/root/dc1-platform/backend/installers/dcp-agent.tar.gz`.
4. (Optional) Push a config bump so daemons pull the new tarball on next heartbeat — this is the `wants_logs_at`-style mechanism we use for diag refresh.

Long-term we'll automate this with a GitHub Action on tag push; for now it's manual.

---

## Where DCP-specific things live

| What | Where |
|---|---|
| DCP-specific skills | `hermes_cli/skills/dcp/` (and individual skills throughout `optional-skills/` tagged with `domain:dcp`) |
| Cron scripts (diagnostic/maintenance only — these are what the agent still schedules) | `scripts/` — `memory-check.sh`, `disk-cleanup.sh`, `earnings-update.sh`, `security-audit.sh`, `daily-report.sh` |
| Daemon-owned scripts (present in `scripts/` for reference, but **NOT** registered by the agent installer — the daemon runs these) | `heartbeat.sh`, `wireguard-watchdog.sh`, `ollama-watchdog.sh`, `self-update.sh`, `agent-liveness.sh`, `gpu-check.sh` |
| Install topology + daemon pre-flight | `install.sh`, `install.ps1`, `scripts/install-cross-platform.{sh,ps1}` — see "Runtime topology" above |
| SOUL.md (persona) | `hermes_cli/default_soul.py` writes the default; provider's working copy lives at `~/.hermes/SOUL.md` |
| Installer scripts | `scripts/install-agent.sh` (one-line installer hosted at `api.dcp.sa/install/agent`) |
| Provider gateway hook | `hermes_cli/gateway.py` — first-run orchestration when `install_token` exists |

---

## DCP backend surfaces this agent talks to

- `POST https://api.dcp.sa/api/agent/gateway` — LLM brain proxy (provider key auth → DCP picks upstream)
- `POST https://api.dcp.sa/v1/wizard/handshake` — first-run consumes the install_token
- `GET  https://api.dcp.sa/api/providers/:id/diag/wg` — read-only WG diagnostic (new 2026-05-13)
- `POST https://api.dcp.sa/api/providers/:id/agent-liveness` — 60s beacon (new 2026-05-13, agent-side implementation pending — see `docs/hermes-liveness-spec.md` in the backend repo)
- `POST https://api.dcp.sa/api/providers/:id/agent-logs` — log tail upload

When implementing anything that needs central observability, prefer adding a backend endpoint and calling it from here over local-only logging.

---

## Getting unstuck

If your install hangs at `sudo mkdir -p /etc/systemd/system/ollama.service.d` for more than a minute:
- That's the `curl | sudo bash` password prompt issue. sudo is waiting for a TTY that doesn't exist on a pipe.
- Workaround: run the install with `sudo -v` first (caches sudo creds), then re-run the installer.
- Permanent fix: open a PR using `sudo -n` (non-interactive) in `scripts/install.sh` and surface a clearer error if sudo isn't cached.

If `hermes gateway run` exits immediately with "No messaging platforms enabled":
- The gateway is a bridge for Telegram/Slack/etc. Without one configured, it exits cleanly.
- For local web UI, use `hermes dashboard --port 8642 --tui` instead.

If the agent thinks it's not a provider:
- Check `~/.dcp/install_token` exists.
- Check `~/.hermes/.env` has `DCP_PROVIDER_KEY` set.
- Verify the key is valid: `curl -sS -H "x-provider-key: $DCP_PROVIDER_KEY" https://api.dcp.sa/api/providers/me`.

If anything else breaks, the daemon at gate0 has direct mesh access — drop into the `/dev` Telegram thread with the symptom + last 20 lines of `~/.dcp/agent.log` and someone (often `@dcp_dev_bot`) will diagnose.

---

## First PR — a low-stakes path to your first merge

1. Read this file end-to-end. If you found a step that didn't work or a fact that's wrong: that's your first PR.
2. Edit `DCP-ONBOARDING.md` with the fix.
3. Open the PR: `gh pr create --title "doc: fix X in DCP-ONBOARDING" --body "..."`
4. Tag the reviewer (anyone in `dhnpmp-tech`).

That's it. Don't overthink the first one. The conventions are the conventions; the bar is "did you read what's here and improve it."
