---
name: dcp-first-run-setup
description: "One-time setup: grant DCP Agent admin access on macOS, Linux, and Windows."
version: 1.0.0
metadata:
  hermes:
    tags: [dcp, setup, permissions, admin, first-run, sudo, install]
---

# DCP Agent First-Run Setup

On first startup, the DCP Agent needs admin access to manage WireGuard, GPU monitoring, and system services. This skill handles the one-time permission grant across all platforms.

## IMPORTANT: Run this on first install only

The agent should detect if it's the first run by checking if `~/.dcp/agent-initialized` exists. If not, run this setup.

## macOS Setup

```bash
# 1. Detect current username
CURRENT_USER=$(whoami)

# 2. Create sudoers file for passwordless DCP commands
sudo tee /etc/sudoers.d/dcp-agent << SUDOERS
# DCP Agent — passwordless sudo for provider management
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/wg, /usr/bin/wg-quick, /usr/local/bin/wg, /usr/local/bin/wg-quick, /opt/homebrew/bin/wg, /opt/homebrew/bin/wg-quick
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/sbin/powermetrics
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/sbin/networksetup
$CURRENT_USER ALL=(ALL) NOPASSWD: /sbin/ifconfig
SUDOERS
sudo chmod 440 /etc/sudoers.d/dcp-agent

# 3. Mark as initialized
mkdir -p ~/.dcp && touch ~/.dcp/agent-initialized
echo "macOS admin access configured"
```

The user will be prompted for their password ONCE by sudo. After that, the agent runs these commands without any password.

## Linux Setup

```bash
# 1. Detect current username
CURRENT_USER=$(whoami)

# 2. Create sudoers file
sudo tee /etc/sudoers.d/dcp-agent << SUDOERS
# DCP Agent — passwordless sudo for provider management
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/wg, /usr/bin/wg-quick
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/nvidia-smi
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ollama
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart wg-quick@wg0
$CURRENT_USER ALL=(ALL) NOPASSWD: /sbin/ip
SUDOERS
sudo chmod 440 /etc/sudoers.d/dcp-agent

# 3. Mark as initialized
mkdir -p ~/.dcp && touch ~/.dcp/agent-initialized
echo "Linux admin access configured"
```

## Windows Setup

On Windows, the DCP installer already runs as Administrator. The agent needs:

```powershell
# 1. Create scheduled task that runs agent as SYSTEM (full admin)
$action = New-ScheduledTaskAction -Execute "python" -Argument "$env:LOCALAPPDATA\dcp-agent\run_agent.py"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName "DCP Agent" -Action $action -Trigger $trigger -Principal $principal

# 2. Firewall rules (already handled by installer, but verify)
New-NetFirewallRule -DisplayName "DCP Mesh Allow" -Direction Inbound -RemoteAddress 10.8.0.0/24 -Action Allow -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "DCP Ollama In" -Direction Inbound -LocalPort 11434 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue

# 3. Mark as initialized
New-Item -ItemType Directory -Path "$env:LOCALAPPDATA\dcp-agent" -Force | Out-Null
New-Item -ItemType File -Path "$env:LOCALAPPDATA\dcp-agent\agent-initialized" -Force | Out-Null
Write-Host "Windows admin access configured"
```

## Detection logic

The agent should run this check at startup:
```bash
# Check if first run
if [ ! -f ~/.dcp/agent-initialized ]; then
    echo "First run detected — requesting admin access..."
    # Run platform-specific setup above
else
    echo "Already initialized"
fi
```

## What the user sees

**First startup only:**
> "DCP Agent needs admin access to manage your GPU, WireGuard tunnel, and inference engine.
> This is a one-time setup. You'll be asked for your password once — after that, the agent
> runs autonomously. Grant access? [Yes/No]"

After they confirm and enter their password once, the agent never asks again.
