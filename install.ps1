# DCP Agent Installer — Windows
# Usage: powershell -ExecutionPolicy Bypass -File install.ps1 -Key YOUR_PROVIDER_KEY
# Or:    Invoke-WebRequest -Uri 'https://dcp.sa/agent-install.ps1' -OutFile install.ps1; .\install.ps1 -Key YOUR_KEY
param(
    [Parameter(Mandatory=$true)]
    [string]$Key
)

$ErrorActionPreference = "Stop"
$MINIMAX_KEY = "sk-cp-6Cm-ITGsSETwJ65ReXvtBWvl6DUnngu77j0ioIz3heBS43rxrw69g-4dpIldNcQl7Jn0W0Mt7_dONjS89k8VnFa1xTTPNPSxM57e8xaVjxQHN9kY60swqIQ"
$DCP_DIR = "$env:LOCALAPPDATA\dcp-agent"
$AGENT_DIR = "$DCP_DIR\agent"

Write-Host "=== DCP Agent Installer (Windows) ===" -ForegroundColor Cyan
Write-Host "Provider key: $($Key.Substring(0,20))..."

# 1. Create directories
New-Item -ItemType Directory -Path $DCP_DIR -Force | Out-Null

# 2. Check/install Python
$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $python) {
    Write-Host "Installing Python via winget..."
    winget install Python.Python.3.11 --accept-package-agreements --accept-source-agreements
    $env:PATH = "$env:LOCALAPPDATA\Programs\Python\Python311;$env:LOCALAPPDATA\Programs\Python\Python311\Scripts;$env:PATH"
}
Write-Host "Python: $(python --version 2>&1)"

# 3. Install uv
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Host "Installing uv..."
    Invoke-WebRequest -Uri "https://astral.sh/uv/install.ps1" -OutFile "$env:TEMP\uv-install.ps1"
    & "$env:TEMP\uv-install.ps1"
    $env:PATH = "$env:USERPROFILE\.local\bin;$env:PATH"
}

# 4. Clone or update
if (Test-Path "$AGENT_DIR\.git") {
    Write-Host "Updating DCP Agent..."
    Push-Location $AGENT_DIR; git pull --ff-only 2>$null; Pop-Location
} else {
    Write-Host "Installing DCP Agent..."
    git clone https://github.com/dhnpmp-tech/dcp-agent.git $AGENT_DIR
}
Set-Location $AGENT_DIR

# 5. Create venv and install
Write-Host "Setting up environment..."
uv venv .venv --python 3.11 2>$null
& .venv\Scripts\Activate.ps1
uv pip install -e . 2>$null

# 6. Write config
Write-Host "Configuring..."
$hermesDir = "$env:USERPROFILE\.hermes"
New-Item -ItemType Directory -Path $hermesDir -Force | Out-Null

$envPath = "$AGENT_DIR\.env"
@"
MINIMAX_API_KEY=$MINIMAX_KEY
TELEGRAM_BOT_TOKEN=8397318012:AAEVIyEYiAM8rckObwHGjJKut6Q9nZv25f4
DCP_API_URL=https://api.dcp.sa
DCP_PROVIDER_KEY=$Key
"@ | Set-Content $envPath

# Restrict .env ACL to the current user only — without this, other local
# accounts (or low-priv malware running as another user) can read the
# MiniMax key, Telegram bot token, and DCP provider key.
try {
    $acl = Get-Acl $envPath
    $acl.SetAccessRuleProtection($true, $false)
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $me, "FullControl", "Allow")
    $acl.SetAccessRule($rule)
    Set-Acl $envPath $acl
} catch {
    Write-Warning "Could not harden ACL on $envPath — file may be readable by other local users."
}

# 7. Firewall rules
Write-Host "Configuring firewall..."
New-NetFirewallRule -DisplayName "DCP Mesh Allow" -Direction Inbound -RemoteAddress 10.8.0.0/24 -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName "DCP Ollama In" -Direction Inbound -LocalPort 11434 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null

# 8. Set Ollama env vars permanently
[System.Environment]::SetEnvironmentVariable("OLLAMA_HOST", "0.0.0.0", "User")
[System.Environment]::SetEnvironmentVariable("OLLAMA_KEEP_ALIVE", "-1", "User")

# 9. Create launcher
@"
Set-Location $AGENT_DIR
& .venv\Scripts\Activate.ps1
hermes gateway start
"@ | Set-Content "$DCP_DIR\start-agent.ps1"

# 10. Install as scheduled task (runs at startup as current user)
$action = New-ScheduledTaskAction -Execute "powershell" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$DCP_DIR\start-agent.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogon
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "DCP Agent" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Host "Installed as Windows scheduled task (auto-starts on login)"

# 10b. Provision DCP provider stack (skills + scheduled tasks + daemon + liveness).
# Mirrors install.sh on Unix; gives curl|iex users the same final state as
# the heavyweight installer.
$HermesHome = "$env:USERPROFILE\.hermes"
if (Test-Path "$AGENT_DIR\skills\dcp") {
    $dcpDst = "$HermesHome\skills\dcp"
    New-Item -ItemType Directory -Path $dcpDst -Force | Out-Null
    Copy-Item -Path "$AGENT_DIR\skills\dcp\*" -Destination $dcpDst -Recurse -Force
    Write-Host "DCP skills (19) synced to $dcpDst"
}
$helper = "$AGENT_DIR\scripts\install-cross-platform.ps1"
if (Test-Path $helper) {
    try {
        . $helper
        Install-DcpProviderStack -DcpDir $DCP_DIR -HermesHome $HermesHome -InstallDir $AGENT_DIR
    } catch {
        Write-Host "WARN: provider stack provisioning hit errors: $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "WARN: install-cross-platform.ps1 missing; tasks + liveness not installed." -ForegroundColor Yellow
}

# 11. Mark initialized
New-Item -ItemType File -Path "$DCP_DIR\agent-initialized" -Force | Out-Null

# 12. Start now
Write-Host ""
Write-Host "=== DCP Agent installed ===" -ForegroundColor Green
Write-Host "Chat:     cd $AGENT_DIR; .venv\Scripts\Activate.ps1; hermes chat --yolo"
Write-Host "Status:   hermes status"
Write-Host "Telegram: message @NexusDatacenter_bot"

# Start the gateway in background
Start-Process powershell -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$DCP_DIR\start-agent.ps1`"" -WindowStyle Hidden
Write-Host "Agent started in background."
