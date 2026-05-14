#!/bin/bash
# install-cross-platform.sh
# Shared helpers for installing the full DCP provider stack:
#   - DCP skills sync into ~/.hermes/skills/
#   - Cron jobs (Linux crontab / macOS crontab)
#   - dcp_daemon.py download + launch wrapper
#   - Hermes liveness beacon (agent-liveness.sh)
#
# Sourced by:
#   - install.sh                (root-level "quick" installer)
#   - scripts/install.sh        (heavyweight installer)
#
# All operations are IDEMPOTENT: marker-fenced blocks in crontab,
# guarded directory creation, hash-checked skill sync.
#
# Required env vars (caller must export before sourcing):
#   HERMES_HOME       e.g. $HOME/.hermes
#   DCP_DIR           e.g. $HOME/.dcp
#   INSTALL_DIR       (optional) e.g. $HOME/.hermes/hermes-agent
#                     Used to source-copy skills if api.dcp.sa is unreachable.
#
# This file is intentionally bash-only (no zsh-isms). Caller chooses shell.

set -u

# --------------------------------------------------------------------------
# Logging helpers (no-op if caller already defined them).
# `type -t` works in both bash and zsh (when sh emulation is off); `command
# -v` doesn't distinguish functions from external commands, so we use both.
# --------------------------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
    log_info()    { echo "[INFO]  $*"; }
fi
if ! command -v log_success >/dev/null 2>&1; then
    log_success() { echo "[OK]    $*"; }
fi
if ! command -v log_warn >/dev/null 2>&1; then
    log_warn()    { echo "[WARN]  $*" >&2; }
fi
if ! command -v log_error >/dev/null 2>&1; then
    log_error()   { echo "[ERROR] $*" >&2; }
fi

# --------------------------------------------------------------------------
# DCP install URLs (override via env for staging/dev)
# --------------------------------------------------------------------------
DCP_INSTALLER_BASE="${DCP_INSTALLER_BASE:-https://api.dcp.sa/installers}"
DCP_DAEMON_URL="${DCP_DAEMON_URL:-$DCP_INSTALLER_BASE/dcp_daemon.py}"

# Marker fences used in crontab so reruns replace, never duplicate.
DCP_CRON_BEGIN="# DCP_CRON_BEGIN -- managed by dcp-agent install"
DCP_CRON_END="# DCP_CRON_END"
DCP_LIVENESS_BEGIN="# DCP_LIVENESS_BEGIN -- managed by dcp-agent install"
DCP_LIVENESS_END="# DCP_LIVENESS_END"

# --------------------------------------------------------------------------
# dcp_install_scripts_dir
# Ensure ~/.dcp/scripts/ exists and copy the bundled watchdog scripts there.
# Cron entries reference this directory, so it must be populated regardless
# of which installer entry point is used.
# --------------------------------------------------------------------------
dcp_install_scripts_dir() {
    local dest="$DCP_DIR/scripts"
    mkdir -p "$dest"

    # Prefer the in-repo scripts/ directory (set by either installer).
    local src=""
    if [ -n "${INSTALL_DIR:-}" ] && [ -d "$INSTALL_DIR/scripts" ]; then
        src="$INSTALL_DIR/scripts"
    elif [ -d "$(dirname "${BASH_SOURCE[0]}")" ]; then
        src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi

    if [ -n "$src" ] && [ -d "$src" ]; then
        for s in ollama-watchdog.sh wireguard-watchdog.sh memory-check.sh \
                 disk-cleanup.sh earnings-update.sh security-audit.sh \
                 daily-report.sh self-update.sh agent-liveness.sh \
                 heartbeat.sh gpu-check.sh; do
            if [ -f "$src/$s" ]; then
                # Always refresh -- these are version-pinned by the install,
                # and users aren't expected to hand-edit them.
                cp -f "$src/$s" "$dest/$s"
                chmod +x "$dest/$s"
            fi
        done
        log_success "Watchdog scripts installed to $dest"
    else
        log_warn "No source scripts/ directory found; cron entries may target missing files."
    fi
}

# --------------------------------------------------------------------------
# dcp_install_daemon
# Download dcp_daemon.py from api.dcp.sa, fall back to bundled copy if any.
# --------------------------------------------------------------------------
dcp_install_daemon() {
    local dest="$DCP_DIR/dcp_daemon.py"
    mkdir -p "$DCP_DIR"
    local installed=0

    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL --max-time 20 -o "$dest.new" "$DCP_DAEMON_URL"; then
            mv -f "$dest.new" "$dest"
            chmod 0755 "$dest"
            log_success "Downloaded dcp_daemon.py from $DCP_DAEMON_URL"
            installed=1
        else
            rm -f "$dest.new"
            log_warn "Could not fetch dcp_daemon.py from $DCP_DAEMON_URL (network/CDN issue)."
        fi
    fi

    if [ "$installed" -eq 0 ] && [ -n "${INSTALL_DIR:-}" ] && [ -f "$INSTALL_DIR/scripts/dcp_daemon.py" ]; then
        cp -f "$INSTALL_DIR/scripts/dcp_daemon.py" "$dest"
        chmod 0755 "$dest"
        log_success "Installed dcp_daemon.py from bundled fallback"
        installed=1
    fi

    if [ "$installed" -eq 0 ]; then
        log_warn "dcp_daemon.py not installed. Heartbeat and GPU monitoring will not run."
        log_warn "Re-run installer once https://api.dcp.sa/installers/dcp_daemon.py is reachable."
        return 1
    fi

    # Template substitution. The daemon source ships with literal
    # `{{API_KEY}}` / `{{API_URL}}` placeholders so the public installer
    # artifact never bakes in secrets. Anyone who copies the file
    # straight without substituting gets a dead daemon — heartbeat URL
    # parse fails with `Invalid URL '{{API_URL}}/...'`. The Tareq Node 2
    # incident 2026-05-13 was exactly this.
    local key="${DCP_PROVIDER_KEY:-${MINIMAX_API_KEY:-}}"
    local url="${DCP_API_BASE:-https://api.dcp.sa}"
    if [ -z "$key" ]; then
        log_warn "DCP_PROVIDER_KEY not set — dcp_daemon.py templating skipped."
        log_warn "Set DCP_PROVIDER_KEY in ~/.hermes/.env and re-run."
        return 0
    fi
    # Portable sed -i across GNU (Linux) and BSD (macOS): use a -i.bak
    # form and then remove the backup. The OR-fallback handles either.
    if sed -i.bak -e "s|{{API_KEY}}|${key}|g" -e "s|{{API_URL}}|${url}|g" "$dest" 2>/dev/null; then
        :
    else
        sed -i '' -e "s|{{API_KEY}}|${key}|g" -e "s|{{API_URL}}|${url}|g" "$dest"
    fi
    rm -f "${dest}.bak"
    if grep -q '{{API_KEY}}\|{{API_URL}}' "$dest"; then
        log_warn "dcp_daemon.py still contains template placeholders after substitution."
        log_warn "Daemon will fail at runtime. Check sed compatibility on this platform."
        return 1
    fi
    log_success "dcp_daemon.py templated (API_KEY=${key:0:14}..., API_URL=${url})"
    return 0
}

# --------------------------------------------------------------------------
# dcp_grant_wg_capability
# Grant CAP_NET_ADMIN to /usr/bin/wg so the daemon can run `wg show wg0`
# without root. Without this, the :19877 diag endpoint reports null for
# listen_port, transfer_rx/tx, last_handshake_age, etc. — backend can't
# observe real mesh health.
#
# Why setcap on the binary instead of granting the daemon capabilities?
# Because the daemon runs under user-mode systemd (~/.config/systemd/user/)
# and user-mode systemd cannot grant AmbientCapabilities — that's a
# privilege of the root service manager. Granting cap_net_admin+ep on the
# wg binary is the documented Linux pattern for read-only WG telemetry
# from non-root callers, narrower than NOPASSWD sudo on `wg`.
#
# Linux only — macOS uses utun/Network Extension (no wg(8) binary).
# Idempotent: getcap is checked first, setcap is a no-op if already set.
# --------------------------------------------------------------------------
dcp_grant_wg_capability() {
    [ "$(uname)" = "Linux" ] || return 0
    if ! command -v wg >/dev/null 2>&1; then
        return 0  # no WG installed; nothing to do
    fi
    local wg_bin
    wg_bin="$(command -v wg)"
    if ! command -v setcap >/dev/null 2>&1; then
        log_warn "setcap not available — WG diag fields will be null."
        log_warn "Install libcap2-bin (apt) or libcap (yum) to fix."
        return 0
    fi
    # Already granted?
    if getcap "$wg_bin" 2>/dev/null | grep -q cap_net_admin; then
        log_success "wg already has cap_net_admin (no-op)"
        return 0
    fi
    if sudo -n setcap cap_net_admin+ep "$wg_bin" 2>/dev/null; then
        log_success "Granted cap_net_admin to $wg_bin (WG diag fields now visible)"
    else
        log_warn "Could not setcap on $wg_bin (sudo password required)."
        log_warn "Run manually after install: sudo setcap cap_net_admin+ep $wg_bin"
        log_warn "Without this the daemon's :19877 diag returns null WG metrics."
    fi
}

# --------------------------------------------------------------------------
# dcp_install_cron_unix
# Replace any prior DCP_CRON_BEGIN..DCP_CRON_END block in the user's crontab
# with a fresh one. Idempotent: rerunning is safe and never duplicates.
#
# SKIPS heartbeat.sh and gpu-check.sh -- those are owned by dcp_daemon.py
# (see PR #396 :19877 wg_diag_server).
# --------------------------------------------------------------------------
dcp_install_cron_unix() {
    if ! command -v crontab >/dev/null 2>&1; then
        log_warn "crontab not found; skipping cron install."
        log_warn "Install cron (Linux: apt install cron; macOS: built-in) and re-run."
        return 1
    fi

    local scripts="$DCP_DIR/scripts"
    local env_src="$HERMES_HOME/.env"

    # Build the new block. Each line sources ~/.hermes/.env so cron has
    # DCP_PROVIDER_KEY / DCP_API_BASE / DCP_PROVIDER_ID available.
    local prelude="set -a; [ -f $env_src ] && . $env_src; set +a;"

    local new_block
    new_block=$(cat <<CRONBLOCK
$DCP_CRON_BEGIN
# Do not edit between these markers; install.sh rewrites this block.
*/2  * * * * $prelude bash $scripts/ollama-watchdog.sh    >> $DCP_DIR/cron.log 2>&1
*/2  * * * * $prelude bash $scripts/wireguard-watchdog.sh >> $DCP_DIR/cron.log 2>&1
0    * * * * $prelude bash $scripts/memory-check.sh       >> $DCP_DIR/cron.log 2>&1
0    * * * * $prelude bash $scripts/disk-cleanup.sh       >> $DCP_DIR/cron.log 2>&1
0 */6  * * * $prelude bash $scripts/earnings-update.sh    >> $DCP_DIR/cron.log 2>&1
0 */6  * * * $prelude bash $scripts/security-audit.sh     >> $DCP_DIR/cron.log 2>&1
0 3    * * * $prelude bash $scripts/daily-report.sh       >> $DCP_DIR/cron.log 2>&1
0 4    * * * $prelude bash $scripts/self-update.sh        >> $DCP_DIR/cron.log 2>&1
$DCP_LIVENESS_BEGIN
*    * * * * $prelude bash $scripts/agent-liveness.sh     >> $DCP_DIR/liveness.log 2>&1
$DCP_LIVENESS_END
$DCP_CRON_END
CRONBLOCK
)

    # Read current crontab (may be empty / "no crontab for user").
    local current
    current=$(crontab -l 2>/dev/null || true)

    # Strip any previous managed block (between BEGIN/END markers).
    local stripped
    stripped=$(printf '%s\n' "$current" | awk -v B="$DCP_CRON_BEGIN" -v E="$DCP_CRON_END" '
        $0==B {skip=1; next}
        $0==E {skip=0; next}
        !skip {print}
    ')

    # Trim trailing blank lines, then append the new block.
    stripped=$(printf '%s\n' "$stripped" | awk 'NF{p=1} p{print}' | sed -e :a -e '/^$/{$d;N;ba' -e '}')

    printf '%s\n%s\n' "$stripped" "$new_block" | crontab -
    log_success "DCP cron block installed (idempotent, see 'crontab -l')."
}

# --------------------------------------------------------------------------
# dcp_install_launchd_macos
# Optional: install launchd plists if a plist directory ships in the repo.
# Otherwise rely on crontab (cron daemon is present by default on macOS).
# --------------------------------------------------------------------------
dcp_install_launchd_macos() {
    local plist_src=""
    if [ -n "${INSTALL_DIR:-}" ] && [ -d "$INSTALL_DIR/scripts/launchd" ]; then
        plist_src="$INSTALL_DIR/scripts/launchd"
    fi

    if [ -z "$plist_src" ] || [ ! -d "$plist_src" ]; then
        log_info "No launchd plists bundled; using crontab on macOS."
        dcp_install_cron_unix
        return 0
    fi

    local dest="$HOME/Library/LaunchAgents"
    mkdir -p "$dest"
    local count=0
    for p in "$plist_src"/sa.dcp.*.plist; do
        [ -f "$p" ] || continue
        cp -f "$p" "$dest/$(basename "$p")"
        launchctl unload "$dest/$(basename "$p")" 2>/dev/null || true
        launchctl load   "$dest/$(basename "$p")" 2>/dev/null || true
        count=$((count + 1))
    done
    log_success "Installed $count launchd plists into $dest"
}

# --------------------------------------------------------------------------
# dcp_provision_full_stack
# Top-level entry point. Call this AFTER skills_sync has run and AFTER
# ~/.hermes/.env has been written.
# --------------------------------------------------------------------------
dcp_provision_full_stack() {
    log_info "Provisioning DCP provider stack (cron + daemon + liveness + hermes-cron)..."

    mkdir -p "$DCP_DIR" "$HERMES_HOME"
    dcp_install_scripts_dir
    dcp_install_daemon || true   # non-fatal; cron will skip the missing pieces
    dcp_grant_wg_capability        # CAP_NET_ADMIN on /usr/bin/wg (Linux only)
    dcp_install_hermes_scripts     # Copy + env-wrap scripts into ~/.hermes/scripts/
    dcp_register_hermes_cron       # Register jobs with in-process orchestrator

    local os
    os="$(uname -s)"
    case "$os" in
        Darwin)
            dcp_install_launchd_macos
            ;;
        Linux)
            # OS-cron now carries only SURVIVAL watchdogs (must run even if
            # Hermes itself dies). Everything else moved to hermes-cron above.
            dcp_install_cron_unix_survival_only
            ;;
        *)
            log_warn "Unsupported OS for cron auto-install: $os"
            log_warn "Falling back to crontab (best effort)."
            dcp_install_cron_unix_survival_only || true
            ;;
    esac

    log_success "DCP provider stack provisioned."
}

# --------------------------------------------------------------------------
# dcp_install_hermes_scripts
# Copy watchdog scripts into ~/.hermes/scripts/ (hermes cron requires real
# files under this dir — symlinks are rejected as "path traversal"). Inject
# an env-sourcing prologue so each script can read DCP_PROVIDER_KEY /
# DCP_API_BASE without the caller having to set up env first.
# --------------------------------------------------------------------------
dcp_install_hermes_scripts() {
    local src="$DCP_DIR/scripts"
    local dest="$HERMES_HOME/scripts"
    mkdir -p "$dest"
    local scripts="heartbeat.sh gpu-check.sh ollama-watchdog.sh wireguard-watchdog.sh memory-check.sh earnings-update.sh self-update.sh disk-cleanup.sh security-audit.sh daily-report.sh"
    local env_block='# ─── DCP env (auto-injected by orchestrator setup) ───
set -a
[ -f "$HOME/.dcp/agent/.env" ] && . "$HOME/.dcp/agent/.env"
[ -f "$HOME/.hermes/.env" ] && . "$HOME/.hermes/.env"
set +a
'
    for f in $scripts; do
        if [ -f "$src/$f" ]; then
            cp -f "$src/$f" "$dest/$f"
            chmod +x "$dest/$f"
            # Idempotent env-wrap injection right after shebang
            if ! grep -q "auto-injected by orchestrator" "$dest/$f"; then
                awk -v block="$env_block" 'NR==1{print;print block;next}{print}' "$dest/$f" > "$dest/$f.tmp" && mv "$dest/$f.tmp" "$dest/$f"
                chmod +x "$dest/$f"
            fi
        fi
    done
    log_success "Hermes scripts dir populated ($(ls "$dest" 2>/dev/null | wc -l | tr -d ' ') files)"
}

# --------------------------------------------------------------------------
# dcp_register_hermes_cron
# Register the DCP orchestration schedule with `hermes cron`. The in-process
# scheduler runs each script on its cron schedule when the gateway is
# running. --no-agent means the script IS the job (no LLM tokens burned).
#
# Why hermes-cron over OS crontab as primary:
#   - Failure-tracking: hermes records each run's exit code and last_run ts
#   - LLM escalation: a future iteration can switch select jobs from
#     --no-agent to LLM-injected so the agent reacts to failures
#   - Single source of truth: `hermes cron list` shows everything
#   - Survives OS without crontab (e.g. minimal Alpine containers)
#
# OS-cron still carries the SURVIVAL watchdogs (ollama, wireguard, liveness)
# so the provider can recover even if Hermes itself dies.
# --------------------------------------------------------------------------
dcp_register_hermes_cron() {
    local hermes_bin="${HERMES_BIN:-$INSTALL_DIR/venv/bin/hermes}"
    if [ ! -x "$hermes_bin" ]; then
        hermes_bin="$(command -v hermes 2>/dev/null)"
    fi
    if [ -z "$hermes_bin" ] || [ ! -x "$hermes_bin" ]; then
        log_warn "hermes binary not found — skipping hermes-cron registration."
        log_warn "Re-run installer after Hermes Agent is installed."
        return 0
    fi
    # Wipe any prior DCP jobs (idempotent on rerun)
    "$hermes_bin" cron list 2>/dev/null | awk '
        /^  [0-9a-f]+ \[/{cur=$1}
        /Name:[[:space:]]+dcp-/{print cur}
    ' | while read -r id; do
        [ -n "$id" ] && "$hermes_bin" cron remove "$id" >/dev/null 2>&1
    done
    # Register the schedule. Per-minute jobs for live watchdogs; longer for
    # maintenance. dcp_daemon.py handles its own heartbeat — hermes-heartbeat
    # is the secondary path / fallback.
    "$hermes_bin" cron create "* * * * *"      --name dcp-heartbeat          --script heartbeat.sh           --no-agent >/dev/null 2>&1 || true
    "$hermes_bin" cron create "* * * * *"      --name dcp-gpu-thermal        --script gpu-check.sh           --no-agent >/dev/null 2>&1 || true
    "$hermes_bin" cron create "*/2 * * * *"    --name dcp-ollama-watchdog    --script ollama-watchdog.sh     --no-agent >/dev/null 2>&1 || true
    "$hermes_bin" cron create "*/2 * * * *"    --name dcp-wireguard-watchdog --script wireguard-watchdog.sh  --no-agent >/dev/null 2>&1 || true
    "$hermes_bin" cron create "*/2 * * * *"    --name dcp-memory-check       --script memory-check.sh        --no-agent >/dev/null 2>&1 || true
    "$hermes_bin" cron create "*/15 * * * *"   --name dcp-earnings-cache     --script earnings-update.sh     --no-agent >/dev/null 2>&1 || true
    "$hermes_bin" cron create "0 */6 * * *"    --name dcp-self-update        --script self-update.sh         --no-agent >/dev/null 2>&1 || true
    "$hermes_bin" cron create "0 */6 * * *"    --name dcp-disk-cleanup       --script disk-cleanup.sh        --no-agent >/dev/null 2>&1 || true
    "$hermes_bin" cron create "0 1 * * *"      --name dcp-security-audit     --script security-audit.sh      --no-agent >/dev/null 2>&1 || true
    "$hermes_bin" cron create "0 5 * * *"      --name dcp-daily-report       --script daily-report.sh        --no-agent >/dev/null 2>&1 || true
    local count
    count="$("$hermes_bin" cron list 2>/dev/null | grep -c '^  [0-9a-f]\{12\} \[active')"
    log_success "Registered $count hermes-cron jobs (dcp-* prefix)"
}

# --------------------------------------------------------------------------
# dcp_install_cron_unix_survival_only
# Thinned OS crontab — only the watchdogs that must survive Hermes dying.
# All other watchdogs are managed by hermes-cron (above). Marker-fenced
# # DCP_CRON_BEGIN / # DCP_CRON_END so reruns replace cleanly.
# --------------------------------------------------------------------------
dcp_install_cron_unix_survival_only() {
    if ! command -v crontab >/dev/null 2>&1; then
        log_warn "crontab unavailable — survival watchdogs not scheduled."
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    # Strip prior block, keep everything else
    (crontab -l 2>/dev/null || true) | awk '
        BEGIN{in_block=0}
        /^# DCP_CRON_BEGIN/{in_block=1; next}
        /^# DCP_CRON_END/{in_block=0; next}
        in_block==0{print}
    ' > "$tmp"
    cat >> "$tmp" <<EOF
# DCP_CRON_BEGIN (survival watchdogs only — hermes-cron handles the rest)
*/2 * * * * \$HOME/.hermes/scripts/ollama-watchdog.sh >> \$HOME/.dcp/logs/cron.log 2>&1
*/2 * * * * \$HOME/.hermes/scripts/wireguard-watchdog.sh >> \$HOME/.dcp/logs/cron.log 2>&1
# DCP_CRON_END
EOF
    crontab "$tmp" && log_success "OS crontab installed (2 survival watchdogs)"
    rm -f "$tmp"
}
