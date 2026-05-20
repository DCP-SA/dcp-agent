#!/bin/bash
# DCP Agent Installer — macOS & Linux
# Usage: curl -fsSL https://dcp.sa/agent-install.sh | bash -s -- --key YOUR_PROVIDER_KEY
set -e

PROVIDER_KEY=""
DCP_DIR="$HOME/.dcp"
AGENT_DIR="$DCP_DIR/agent"
# Master MiniMax key + NexusDatacenter bot token used to live here. They're
# now server-side only — providers never receive master credentials.
# Agent calls api.dcp.sa/api/agent/gateway with DCP_PROVIDER_KEY; the gateway
# proxies to MiniMax server-side. (Audit 2026-05-14, see PR removing them.)

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --key) PROVIDER_KEY="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$PROVIDER_KEY" ]; then
  echo "Usage: ./install.sh --key YOUR_DCP_PROVIDER_KEY"
  echo "Get your key from https://dcp.sa/setup"
  exit 1
fi

echo "=== DCP Agent Installer ==="
echo "Provider key: ${PROVIDER_KEY:0:20}..."

# 0. Pre-flight: verify sudo credentials are cached.
#
# This installer writes /etc/sudoers.d/dcp-agent (and may apt-get install
# python3) which requires root.  When invoked via `curl ... | sudo bash`
# or `curl ... | bash` over a pipe, stdin is the pipe, so sudo cannot
# prompt for a password and hangs forever.  Tareq Node 2 hung 3h30m on
# this path before manual intervention.
#
# Fail fast with a clear instruction instead of hanging.  We require
# `sudo -n true` to succeed (creds already cached) so every later sudo
# call can safely use `sudo -n` and propagate failures.
if ! command -v sudo &>/dev/null; then
  echo "ERROR: sudo not found on PATH."
  echo "       This installer needs root to write /etc/sudoers.d/dcp-agent."
  echo "       Install sudo, or run this script as root directly."
  exit 1
fi

if ! sudo -n true 2>/dev/null; then
  echo "ERROR: sudo credentials are not cached."
  echo ""
  echo "When this installer is piped to bash (curl ... | bash) sudo cannot"
  echo "prompt for a password and the install hangs silently."
  echo ""
  echo "Fix: cache your sudo credentials first, then re-run the installer:"
  echo ""
  echo "    sudo -v"
  echo "    curl -fsSL https://api.dcp.sa/install/agent | bash -s -- --key $PROVIDER_KEY"
  echo ""
  exit 1
fi

# 1. Create DCP directory
mkdir -p "$DCP_DIR"

# 2. Check Python 3.11+
if ! command -v python3 &>/dev/null; then
  echo "Installing Python..."
  if [[ "$(uname)" == "Darwin" ]]; then
    brew install python@3.11
  else
    sudo -n apt-get update && sudo -n apt-get install -y python3.11 python3.11-venv
  fi
fi

PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
echo "Python: $PYTHON_VERSION"

# 3. Install uv (fast Python package manager)
if ! command -v uv &>/dev/null; then
  echo "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

# 4. Clone or update DCP Agent
if [ -d "$AGENT_DIR" ]; then
  echo "Updating DCP Agent..."
  cd "$AGENT_DIR" && git pull --ff-only 2>/dev/null || true
else
  echo "Installing DCP Agent..."
  git clone https://github.com/DCP-SA/dcp-agent.git "$AGENT_DIR"
fi
cd "$AGENT_DIR"

# 5. Create venv and install
echo "Setting up environment..."
uv venv .venv --python 3.11 2>/dev/null || python3 -m venv .venv
source .venv/bin/activate
# Install with [web] extra so `hermes dashboard --tui` has fastapi + uvicorn.
# Without this, the dashboard fails with ModuleNotFoundError: No module
# named 'fastapi' (surfaced on Tareq Node 2).
uv pip install -e '.[web]' 2>/dev/null || pip install -e '.[web]'

# 6. Write config
echo "Configuring..."
mkdir -p "$HOME/.hermes"

# Note on auth (audit 2026-05-14, PR #15 + this PR):
#   MINIMAX_API_KEY is the provider key the agent presents to the DCP
#   gateway (api.dcp.sa/api/agent/gateway). The gateway authenticates by
#   the provider key prefix and proxies to MiniMax with the server-side
#   master key — providers never see the master. The master key used to
#   be baked here (P0-1); it's gone now.
#   TELEGRAM_BOT_TOKEN is no longer baked. Providers that want their own
#   TG bot wire it via `hermes setup` after install.
#
# umask 077 ensures the file is created mode 600 even on systems with a
# permissive default umask, before any secret hits disk.
(
  umask 077
  cat > "$AGENT_DIR/.env" << EOF
MINIMAX_API_KEY=$PROVIDER_KEY
MINIMAX_BASE_URL=https://api.dcp.sa/api/agent/gateway
DCP_API_URL=https://api.dcp.sa
DCP_PROVIDER_KEY=$PROVIDER_KEY
EOF
)
# Defence-in-depth: explicit chmod in case the umask trick was bypassed
# (e.g. file already existed at 0644 before the redirect).
chmod 600 "$AGENT_DIR/.env"

# Write hermes config
python3 -c "
import yaml, os
config_path = os.path.expanduser('~/.hermes/config.yaml')
cfg = {}
if os.path.exists(config_path):
    with open(config_path) as f:
        cfg = yaml.safe_load(f) or {}
cfg['model'] = 'MiniMax-M2.7-highspeed'
# DCP Agent runs ONLY operational tasks on the provider machine.
# It is NOT a general-purpose agent — never executes renter prompts or web content.
# All DCP ops (heartbeat, model pull, gpu check, wg watchdog) run via cron scripts
# directly, not through the brain. The brain therefore needs no auto-shell powers.
cfg['approvals'] = {'mode': 'approve', 'timeout': 60, 'cron_mode': 'deny'}
cfg['command_allowlist'] = []
cfg['hooks_auto_accept'] = False
with open(config_path, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False)
print('Config written')
"

# 7. Platform-specific admin access (one-time)
if [ ! -f "$DCP_DIR/agent-initialized" ]; then
  echo ""
  echo "=== One-time admin access setup ==="
  echo "DCP Agent needs admin access for WireGuard and GPU monitoring."
  echo "You'll be asked for your password ONCE — after this, the agent runs autonomously."
  echo ""

  CURRENT_USER=$(whoami)

  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS
    WG_PATHS="/usr/bin/wg, /usr/bin/wg-quick, /usr/local/bin/wg, /usr/local/bin/wg-quick, /opt/homebrew/bin/wg, /opt/homebrew/bin/wg-quick"
    sudo -n tee /etc/sudoers.d/dcp-agent > /dev/null << SUDOERS
$CURRENT_USER ALL=(ALL) NOPASSWD: $WG_PATHS
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/sbin/powermetrics
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/sbin/networksetup
$CURRENT_USER ALL=(ALL) NOPASSWD: /sbin/ifconfig
SUDOERS
    sudo -n chmod 440 /etc/sudoers.d/dcp-agent
  else
    # Linux
    sudo -n tee /etc/sudoers.d/dcp-agent > /dev/null << SUDOERS
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/wg, /usr/bin/wg-quick
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ollama
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart wg-quick@wg0
$CURRENT_USER ALL=(ALL) NOPASSWD: /sbin/ip
SUDOERS
    sudo -n chmod 440 /etc/sudoers.d/dcp-agent
  fi

  touch "$DCP_DIR/agent-initialized"
  echo "Admin access configured."
fi

# 8. Create launcher script
cat > "$DCP_DIR/start-agent.sh" << 'LAUNCHER'
#!/bin/bash
cd ~/.dcp/agent
source .venv/bin/activate
exec hermes gateway start
LAUNCHER
chmod +x "$DCP_DIR/start-agent.sh"

# 9. Install as background service
if [[ "$(uname)" == "Darwin" ]]; then
  # macOS launchd
  cat > "$HOME/Library/LaunchAgents/sa.dcp.agent.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>sa.dcp.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DCP_DIR/start-agent.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DCP_DIR/agent.log</string>
  <key>StandardErrorPath</key><string>$DCP_DIR/agent.err</string>
</dict>
</plist>
PLIST
  launchctl load "$HOME/Library/LaunchAgents/sa.dcp.agent.plist" 2>/dev/null
  echo "Installed as macOS service (auto-starts on boot)"
else
  # Linux systemd
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/dcp-agent.service" << UNIT
[Unit]
Description=DCP Agent
After=network-online.target

[Service]
ExecStart=$DCP_DIR/start-agent.sh
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable dcp-agent
  systemctl --user start dcp-agent
  echo "Installed as systemd user service (auto-starts on boot)"
fi

# 10. Provision DCP provider stack (skills + cron + daemon + liveness).
# This is the same provisioning the heavyweight installer runs, exposed
# here so `curl | bash` installs end up with the same final state.
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
INSTALL_DIR="$AGENT_DIR"
export DCP_DIR HERMES_HOME INSTALL_DIR

# Make sure DCP skills land in ~/.hermes/skills/dcp/ even though the
# quick installer skips skills_sync.py.
if [ -d "$AGENT_DIR/skills/dcp" ]; then
  mkdir -p "$HERMES_HOME/skills/dcp"
  cp -r "$AGENT_DIR/skills/dcp/." "$HERMES_HOME/skills/dcp/"
  echo "DCP skills (19) synced to $HERMES_HOME/skills/dcp/"
fi

# Source the shared provisioner.
if [ -f "$AGENT_DIR/scripts/install-cross-platform.sh" ]; then
  # shellcheck disable=SC1091
  . "$AGENT_DIR/scripts/install-cross-platform.sh"
  dcp_provision_full_stack || echo "WARN: provider stack provisioning hit errors (non-fatal)."
else
  echo "WARN: install-cross-platform.sh missing; cron + liveness not installed."
  echo "      Re-run the installer after 'git pull' inside $AGENT_DIR."
fi

echo ""
echo "=== DCP Agent installed ==="
echo "Chat:     cd $AGENT_DIR && source .venv/bin/activate && hermes chat"
echo "Status:   hermes status"
echo "Telegram: message @NexusDatacenter_bot"
echo "Logs:     cat $DCP_DIR/agent.log"
