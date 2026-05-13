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
    log_info "Provisioning DCP provider stack (cron + daemon + liveness)..."

    mkdir -p "$DCP_DIR" "$HERMES_HOME"
    dcp_install_scripts_dir
    dcp_install_daemon || true   # non-fatal; cron will skip the missing pieces

    local os
    os="$(uname -s)"
    case "$os" in
        Darwin)
            dcp_install_launchd_macos
            ;;
        Linux)
            dcp_install_cron_unix
            ;;
        *)
            log_warn "Unsupported OS for cron auto-install: $os"
            log_warn "Falling back to crontab (best effort)."
            dcp_install_cron_unix || true
            ;;
    esac

    log_success "DCP provider stack provisioned."
}
