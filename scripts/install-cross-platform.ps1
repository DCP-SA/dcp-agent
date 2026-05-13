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

function Write-DcpInfo    { param($Msg) Write-Host "[INFO]  $Msg" }
function Write-DcpSuccess { param($Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Write-DcpWarn    { param($Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }

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

    # Job table: name, schtacks /SC + /MO, script
    $jobs = @(
        @{ Name="DCP_OllamaWatchdog";    SC="MINUTE"; MO="2";  Script="ollama-watchdog.sh"    },
        @{ Name="DCP_WireguardWatchdog"; SC="MINUTE"; MO="2";  Script="wireguard-watchdog.sh" },
        @{ Name="DCP_MemoryCheck";       SC="HOURLY"; MO="1";  Script="memory-check.sh"       },
        @{ Name="DCP_DiskCleanup";       SC="HOURLY"; MO="1";  Script="disk-cleanup.sh"       },
        @{ Name="DCP_EarningsUpdate";    SC="HOURLY"; MO="6";  Script="earnings-update.sh"    },
        @{ Name="DCP_SecurityAudit";     SC="HOURLY"; MO="6";  Script="security-audit.sh"     },
        @{ Name="DCP_DailyReport";       SC="DAILY";  MO="1";  Script="daily-report.sh"; ST="03:00" },
        @{ Name="DCP_SelfUpdate";        SC="DAILY";  MO="1";  Script="self-update.sh";  ST="04:00" },
        @{ Name="DCP_AgentLiveness";     SC="MINUTE"; MO="1";  Script="agent-liveness.sh"     }
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
    Write-DcpInfo "Provisioning DCP provider stack (tasks + daemon + liveness)..."

    New-Item -ItemType Directory -Path $DcpDir     -Force | Out-Null
    New-Item -ItemType Directory -Path $HermesHome -Force | Out-Null

    Install-DcpScripts -DcpDir $DcpDir -InstallDir $InstallDir
    [void] (Install-DcpDaemon -DcpDir $DcpDir)
    Install-DcpScheduledTasks -DcpDir $DcpDir -HermesHome $HermesHome

    Write-DcpSuccess "DCP provider stack ready."
}
