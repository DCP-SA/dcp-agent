#!/bin/bash
# DCP Agent Installer — macOS & Linux
# Usage: curl -fsSL https://dcp.sa/agent-install.sh | bash -s -- --key YOUR_PROVIDER_KEY
set -e

PROVIDER_KEY=""
MINIMAX_KEY="sk-cp-6Cm-ITGsSETwJ65ReXvtBWvl6DUnngu77j0ioIz3heBS43rxrw69g-4dpIldNcQl7Jn0W0Mt7_dONjS89k8VnFa1xTTPNPSxM57e8xaVjxQHN9kY60swqIQ"
DCP_DIR="$HOME/.dcp"
AGENT_DIR="$DCP_DIR/agent"

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

# 1. Create DCP directory
mkdir -p "$DCP_DIR"

# 2. Check Python 3.11+
if ! command -v python3 &>/dev/null; then
  echo "Installing Python..."
  if [[ "$(uname)" == "Darwin" ]]; then
    brew install python@3.11
  else
    sudo apt-get update && sudo apt-get install -y python3.11 python3.11-venv
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
  git clone https://github.com/dhnpmp-tech/dcp-agent.git "$AGENT_DIR"
fi
cd "$AGENT_DIR"

# 5. Create venv and install
echo "Setting up environment..."
uv venv .venv --python 3.11 2>/dev/null || python3 -m venv .venv
source .venv/bin/activate
uv pip install -e . 2>/dev/null || pip install -e .

# 6. Write config
echo "Configuring..."
mkdir -p "$HOME/.hermes"

cat > "$AGENT_DIR/.env" << EOF
MINIMAX_API_KEY=$MINIMAX_KEY
TELEGRAM_BOT_TOKEN=8397318012:AAEVIyEYiAM8rckObwHGjJKut6Q9nZv25f4
DCP_API_URL=https://api.dcp.sa
DCP_PROVIDER_KEY=$PROVIDER_KEY
EOF

# Write hermes config
python3 -c "
import yaml, os
config_path = os.path.expanduser('~/.hermes/config.yaml')
cfg = {}
if os.path.exists(config_path):
    with open(config_path) as f:
        cfg = yaml.safe_load(f) or {}
cfg['model'] = 'MiniMax-M2.7-highspeed'
cfg['approvals'] = {'mode': 'yolo', 'timeout': 60, 'cron_mode': 'allow'}
cfg['command_allowlist'] = ['*']
cfg['hooks_auto_accept'] = True
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
    sudo tee /etc/sudoers.d/dcp-agent > /dev/null << SUDOERS
$CURRENT_USER ALL=(ALL) NOPASSWD: $WG_PATHS
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/sbin/powermetrics
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/sbin/networksetup
$CURRENT_USER ALL=(ALL) NOPASSWD: /sbin/ifconfig
SUDOERS
    sudo chmod 440 /etc/sudoers.d/dcp-agent
  else
    # Linux
    sudo tee /etc/sudoers.d/dcp-agent > /dev/null << SUDOERS
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/wg, /usr/bin/wg-quick
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ollama
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart wg-quick@wg0
$CURRENT_USER ALL=(ALL) NOPASSWD: /sbin/ip
SUDOERS
    sudo chmod 440 /etc/sudoers.d/dcp-agent
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

echo ""
echo "=== DCP Agent installed ==="
echo "Chat:     cd $AGENT_DIR && source .venv/bin/activate && hermes chat --yolo"
echo "Status:   hermes status"
echo "Telegram: message @NexusDatacenter_bot"
echo "Logs:     cat $DCP_DIR/agent.log"
