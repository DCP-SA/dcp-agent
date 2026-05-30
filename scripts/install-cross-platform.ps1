# install-cross-platform.ps1
# Shared helpers for installing the full DCP provider stack on Windows:
#   - DCP skills sync into $HermesHome\skills\dcp\
#   - Scheduled Tasks (cron equivalent) via schtasks.exe
#   - dcp_daemon.py download
#   - Hermes liveness beacon (agent-liveness.ps1)
#
# Dot-sourced by:
#   - install.ps1                (root-level quick installer)
#   - scripts\install.ps1        (heavyweight installer)
#
# Idempotent: tasks are deleted-then-recreated, named with a
# "DCP_" prefix so reruns never duplicate.
#
# Required env vars (caller must set before sourcing):
#   $HermesHome      e.g. $env:USERPROFILE\.hermes
#   $DcpDir          e.g. $env:USERPROFILE\.dcp
#   $InstallDir      e.g. $HermesHome\hermes-agent (optional, for fallback)

$ErrorActionPreference = "Stop"

$DcpInstallerBase = if ($env:DCP_INSTALLER_BASE) { $env:DCP_INSTALLER_BASE } else { "https://api.dcp.sa/installers" }
$DcpDaemonUrl     = if ($env:DCP_DAEMON_URL)     { $env:DCP_DAEMON_URL }     else { "$DcpInstallerBase/dcp_daemon.py" }

# Runtime consolidation — backlog gap #6, Phase 0 (decision A: daemon-everywhere).
# The DCP daemon is the SOLE provider runtime; the agent must NOT register its
# own heartbeat/WG/ollama/self-update/liveness loops. Probe the daemon's local
# health endpoint before provisioning the agent as a brain on top.
$DcpDaemonHealthPort = if ($env:DCP_DAEMON_HEALTH_PORT) { [int]$env:DCP_DAEMON_HEALTH_PORT } else { 19876 }
# Scheduled-task names that earlier versions created for daemon-owned runtime
# scripts. We delete these on every run so an upgrade-in-place removes the
# duplicate watchdogs (the Node-2 split-brain).
$DcpLegacyRuntimeTasks = @(
    "DCP_OllamaWatchdog", "DCP_WireguardWatchdog", "DCP_SelfUpdate", "DCP_AgentLiveness"
)

function Write-DcpInfo    { param($Msg) Write-Host "[INFO]  $Msg" }
function Write-DcpSuccess { param($Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Write-DcpWarn    { param($Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-DcpError   { param($Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }

function Test-DcpDaemonRunning {
    # CRITICAL SAFETY CONSTRAINT (decision A): the daemon MUST be present —
    # the agent no longer provides a runtime. Probe :19876 and FAIL LOUDLY if
    # absent. Returns $true if the daemon answers, $false otherwise.
    $port = $DcpDaemonHealthPort
    foreach ($path in @("health", "")) {
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/$path" `
                -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) {
                Write-DcpSuccess "DCP daemon is running (health endpoint :$port reachable)."
                return $true
            }
        } catch { }
    }
    Write-DcpError "DCP daemon NOT detected on http://127.0.0.1:$port."
    Write-DcpError ""
    Write-DcpError "Decision A (daemon-everywhere): the DCP daemon is the SOLE runtime on"
    Write-DcpError "every provider box (heartbeat, WireGuard, model-pull, watchdog, self-update)."
    Write-DcpError "The Hermes agent is an optional brain ON TOP and no longer ships its own"
    Write-DcpError "runtime — so this box currently has NO provider runtime at all."
    Write-DcpError ""
    Write-DcpError "Install the DCP daemon FIRST, then re-run this agent installer."
    Write-DcpError "Get your provider token from https://dcp.sa/setup."
    Write-DcpError "To override in a controlled environment, set DCP_SKIP_DAEMON_CHECK=1"
    Write-DcpError "(NOT recommended on a real provider box)."
    return $false
}

function Install-DcpScripts {
    param(
        [Parameter(Mandatory=$true)] [string]$DcpDir,
        [Parameter(Mandatory=$true)] [string]$InstallDir
    )
    $dest = Join-Path $DcpDir "scripts"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    $src = Join-Path $InstallDir "scripts"
    if (-not (Test-Path $src)) {
        Write-DcpWarn "No scripts/ directory at $src -- watchdogs will not run."
        return
    }

    $files = @(
        "ollama-watchdog.sh", "wireguard-watchdog.sh", "memory-check.sh",
        "disk-cleanup.sh", "earnings-update.sh", "security-audit.sh",
        "daily-report.sh", "self-update.sh", "agent-liveness.sh",
        "heartbeat.sh", "gpu-check.sh"
    )
    foreach ($f in $files) {
        $sp = Join-Path $src $f
        if (Test-Path $sp) {
            Copy-Item -Path $sp -Destination (Join-Path $dest $f) -Force
        }
    }
    Write-DcpSuccess "Watchdog scripts installed to $dest"
}

function Install-DcpDaemon {
    param([Parameter(Mandatory=$true)] [string]$DcpDir)

    $dest = Join-Path $DcpDir "dcp_daemon.py"
    New-Item -ItemType Directory -Path $DcpDir -Force | Out-Null
    try {
        Invoke-WebRequest -Uri $DcpDaemonUrl -OutFile $dest -UseBasicParsing -TimeoutSec 20
        Write-DcpSuccess "Downloaded dcp_daemon.py from $DcpDaemonUrl"
        return $true
    } catch {
        Write-DcpWarn "Could not fetch dcp_daemon.py from $DcpDaemonUrl ($($_.Exception.Message))"
        return $false
    }
}

function Install-DcpScheduledTasks {
    # Windows equivalent of crontab. We use schtasks.exe because it works
    # on every SKU (Home included) and is scriptable without an admin token
    # for per-user tasks.
    #
    # Each task is named "DCP_*" so /Delete /TN "DCP_*" /F could nuke them
    # all in one shot; rerunning this function deletes-then-recreates each
    # task individually, which is the idempotency contract.
    param(
        [Parameter(Mandatory=$true)] [string]$DcpDir,
        [Parameter(Mandatory=$true)] [string]$HermesHome
    )

    # Resolve bash.exe -- Git for Windows / PortableGit / WSL all OK.
    $bash = $null
    foreach ($cand in @(
        "$HermesHome\git\bin\bash.exe",
        "$HermesHome\git\usr\bin\bash.exe",
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )) {
        if (Test-Path $cand) { $bash = $cand; break }
    }

    if (-not $bash) {
        Write-DcpWarn "bash.exe not found; cannot register scheduled tasks."
        Write-DcpWarn "Install Git for Windows or run scripts\install.ps1 first."
        return
    }

    $scripts = Join-Path $DcpDir "scripts"

    # Phase 0 (decision A): delete any daemon-owned runtime tasks created by
    # earlier agent versions so an upgrade-in-place removes the duplicate
    # watchdogs (the Node-2 split-brain). The daemon owns ollama/wireguard/
    # self-update/liveness/heartbeat now.
    foreach ($t in $DcpLegacyRuntimeTasks) {
        schtasks.exe /Delete /TN $t /F *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-DcpInfo "Removed legacy runtime task $t (daemon owns it now)."
        }
    }

    # Job table: name, schtacks /SC + /MO, script.
    # ONLY diagnostic / maintenance jobs — NO runtime watchdogs (heartbeat,
    # ollama, wireguard, self-update, liveness are daemon-owned).
    $jobs = @(
        @{ Name="DCP_MemoryCheck";       SC="HOURLY"; MO="1";  Script="memory-check.sh"       },
        @{ Name="DCP_DiskCleanup";       SC="HOURLY"; MO="1";  Script="disk-cleanup.sh"       },
        @{ Name="DCP_EarningsUpdate";    SC="HOURLY"; MO="6";  Script="earnings-update.sh"    },
        @{ Name="DCP_SecurityAudit";     SC="HOURLY"; MO="6";  Script="security-audit.sh"     },
        @{ Name="DCP_DailyReport";       SC="DAILY";  MO="1";  Script="daily-report.sh"; ST="03:00" }
    )

    foreach ($j in $jobs) {
        $scriptPath = Join-Path $scripts $j.Script
        if (-not (Test-Path $scriptPath)) {
            Write-DcpWarn "Missing $scriptPath -- skipping task $($j.Name)."
            continue
        }
        # Convert Windows path to MSYS/Cygwin POSIX form: C:\foo\bar -> /c/foo/bar
        $posix = $scriptPath -replace '\\','/'
        if ($posix -match '^([A-Za-z]):(.*)$') {
            $posix = '/' + $Matches[1].ToLower() + $Matches[2]
        }
        $tr = "`"$bash`" -lc `"$posix`""

        # Delete existing (ignore failures), then create.
        schtasks.exe /Delete /TN $j.Name /F *> $null

        # NB: $args is an automatic variable in PowerShell; use $taskArgs.
        $taskArgs = @("/Create", "/TN", $j.Name, "/TR", $tr,
                      "/SC", $j.SC, "/MO", $j.MO, "/F")
        if ($j.ContainsKey("ST")) { $taskArgs += @("/ST", $j.ST) }
        # Run only when user is logged on so we don't need stored creds.
        $taskArgs += @("/RL", "LIMITED")

        & schtasks.exe @taskArgs *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-DcpInfo "Registered scheduled task $($j.Name)"
        } else {
            Write-DcpWarn "Failed to register $($j.Name) (exit $LASTEXITCODE)"
        }
    }
    Write-DcpSuccess "DCP scheduled tasks installed (see 'schtasks /Query /TN DCP_*')."
}

function Install-DcpProviderStack {
    param(
        [Parameter(Mandatory=$true)] [string]$DcpDir,
        [Parameter(Mandatory=$true)] [string]$HermesHome,
        [Parameter(Mandatory=$true)] [string]$InstallDir
    )
    Write-DcpInfo "Provisioning DCP provider stack (decision A: daemon is the sole runtime)..."

    New-Item -ItemType Directory -Path $DcpDir     -Force | Out-Null
    New-Item -ItemType Directory -Path $HermesHome -Force | Out-Null

    # CRITICAL SAFETY CONSTRAINT (decision A): never leave a box with no
    # runtime. The agent no longer ships heartbeat/WG/pull/self-update, so the
    # daemon MUST already be installed and answering on :19876 before we
    # provision the agent-as-brain on top. Fail LOUDLY if it isn't.
    # Override (controlled environments only): DCP_SKIP_DAEMON_CHECK=1.
    if ($env:DCP_SKIP_DAEMON_CHECK -eq "1") {
        Write-DcpWarn "DCP_SKIP_DAEMON_CHECK=1 — skipping the daemon pre-flight. The box may"
        Write-DcpWarn "have NO provider runtime if the DCP daemon is not actually installed."
    } elseif (-not (Test-DcpDaemonRunning)) {
        throw "DCP daemon is the required runtime (decision A) and was not detected on :$DcpDaemonHealthPort. Install it first, then re-run."
    }

    Install-DcpScripts -DcpDir $DcpDir -InstallDir $InstallDir
    # Refresh the local dcp_daemon.py reference copy (NOT the agent's runtime).
    [void] (Install-DcpDaemon -DcpDir $DcpDir)
    Install-DcpScheduledTasks -DcpDir $DcpDir -HermesHome $HermesHome

    Write-DcpSuccess "DCP provider stack ready (daemon = runtime, agent = brain on top)."
}
