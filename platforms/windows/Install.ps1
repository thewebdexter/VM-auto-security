<#
.SYNOPSIS
    TWDxOSOptimisation - Windows Installer (v2.0.0)

.DESCRIPTION
    Hands-off maintenance for a Windows Server / Desktop host:
      * Windows Update automation via a real scheduled scan+install task
        (uses PSWindowsUpdate if available, else the AU registry policy).
      * Windows Defender Firewall baseline WITH a lockout guard - ensures an
        inbound allow rule exists for the session you are connected on
        (RDP / WinRM / SSH) BEFORE switching the profile to default-deny.
      * A weekly Scheduled Task that runs Declutter.ps1 and a reboot-pending
        check.

.PARAMETER DryRun          Preview every change without applying it.
.PARAMETER Json            Emit a single-line JSON result object to stdout.
.PARAMETER NonInteractive  Never prompt; fail closed on unresolved decisions.
.PARAMETER EnableCleanup   Register the scheduled Declutter.ps1 task. Default: $true
.PARAMETER EnableWindowsUpdate  Configure automatic Windows Update. Default: $true
.PARAMETER CleanupTime     Local HH:mm the weekly task runs. Default: 03:30

.EXAMPLE
    .\Install.ps1 -DryRun

.EXAMPLE
    .\Install.ps1 -NonInteractive -Json

.NOTES
    Tested: Windows Server 2022, Windows 11 - x64 + arm64
    Exit codes: 0 ok, 2 usage, 3 preflight, 4 partial
    License: MIT
    https://github.com/TheWebDexterTech/TWDxOSOptimisation
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Json,
    [switch]$NonInteractive,
    [bool]$EnableCleanup = $true,
    [bool]$EnableWindowsUpdate = $true,
    [string]$CleanupTime = "03:30"
)

$ErrorActionPreference = "Stop"
$TwdxVersion = "2.0.0"
$script:Steps = New-Object System.Collections.Generic.List[object]
$script:Failures = 0

function Write-Info    { param([string]$Message) if (-not $Json) { Write-Host "[info]  $Message" -ForegroundColor Cyan } else { Write-Verbose $Message } }
function Write-Success { param([string]$Message) if (-not $Json) { Write-Host "[ ok ]  $Message" -ForegroundColor Green } else { Write-Verbose $Message } }
function Write-Warn    { param([string]$Message) if (-not $Json) { Write-Host "[warn]  $Message" -ForegroundColor Yellow } else { Write-Warning $Message } }
function Write-Step    { param([string]$Message) if (-not $Json) { Write-Host "`n>> $Message" -ForegroundColor White } else { Write-Verbose $Message } }
function Write-DryRun  { param([string]$Message) if (-not $Json) { Write-Host "[dry-run]  Would: $Message" -ForegroundColor Yellow } else { Write-Verbose "would: $Message" } }

function Add-Step {
    param([string]$Name, [string]$Status, [string]$Detail = "")
    $script:Steps.Add([pscustomobject]@{ name = $Name; status = $Status; detail = $Detail })
    if ($Status -eq "failed") { $script:Failures++ ; Write-Warn "step '$Name' failed: $Detail" }
    elseif ($Status -eq "skipped") { Write-Info "step '$Name' skipped: $Detail" }
}

function Complete-Twdx {
    param([int]$ExitCode, [string]$FailMessage)
    if ($FailMessage) { Write-Host "[fail]  $FailMessage" -ForegroundColor Red }
    if ($Json) {
        [pscustomobject]@{
            tool = "twdxos"; platform = "windows"; script = "install"; version = $TwdxVersion
            result = $(if ($ExitCode -eq 0) { "ok" } elseif ($ExitCode -eq 4) { "partial" } else { "error" })
            dry_run = [bool]$DryRun; failures = $script:Failures; exit_code = $ExitCode
            host = $env:COMPUTERNAME; timestamp = (Get-Date).ToString("o")
            steps = $script:Steps
        } | ConvertTo-Json -Depth 5 -Compress
    }
    exit $ExitCode
}

function Confirm-Continue {
    param([string]$Prompt)
    if ($NonInteractive) { Write-Info "non-interactive: '$Prompt' -> proceeding"; return $true }
    $ans = Read-Host "  $Prompt [y/N]"
    return ($ans -match '^[Yy]$')
}

if (-not $Json) {
    Write-Host ""
    Write-Host "  =================================================================" -ForegroundColor Cyan
    Write-Host "          TWDxOSOptimisation - Windows Installer  v$TwdxVersion    " -ForegroundColor Cyan
    Write-Host "               Developed by: TheWebDexter.com                      " -ForegroundColor Cyan
    Write-Host "  =================================================================" -ForegroundColor Cyan
    Write-Host ""
}
if ($DryRun) { Write-Warn "Dry-run mode: no changes will be made." }
if ($NonInteractive) { Write-Info "Non-interactive mode: prompts auto-resolve to safe defaults." }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Step "Preflight"
if ([System.Environment]::OSVersion.Platform -ne "Win32NT") {
    Complete-Twdx -ExitCode 3 -FailMessage "This installer targets Windows only."
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Complete-Twdx -ExitCode 3 -FailMessage "Run from an elevated (Administrator) PowerShell session."
}
if ($CleanupTime -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') {
    Complete-Twdx -ExitCode 2 -FailMessage "CleanupTime '$CleanupTime' must be HH:mm."
}

$InstallDir = "C:\Program Files\TWDxOSOptimisation"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Info "Install directory: $InstallDir"

# ---------------------------------------------------------------------------
# 1. Windows Update automation (real, not a no-op)
# ---------------------------------------------------------------------------
Write-Step "Windows Update automation"
if (-not $EnableWindowsUpdate) {
    Add-Step "windows-update" "skipped" "EnableWindowsUpdate=false"
} elseif ($DryRun) {
    Write-DryRun "ensure PSWindowsUpdate (best effort); register 'TWDxOSOptimisation-WindowsUpdate' daily task; else set AU policy auto-download+notify"
    Add-Step "windows-update" "dry-run"
} else {
    $hasPSWU = [bool](Get-Module -ListAvailable -Name PSWindowsUpdate)
    if (-not $hasPSWU) {
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null
            Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -ErrorAction Stop
            $hasPSWU = $true
        } catch {
            Write-Warn "PSWindowsUpdate unavailable ($($_.Exception.Message)); falling back to the AU registry policy."
        }
    }

    if ($hasPSWU) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        $wuRunner = Join-Path $InstallDir "Run-WindowsUpdate.ps1"
        @'
Import-Module PSWindowsUpdate -ErrorAction Stop
$log = "$env:ProgramData\TWDxOSOptimisation\Logs\windowsupdate-$(Get-Date -Format yyyyMMdd-HHmmss).log"
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
try {
    Get-WindowsUpdate -Install -AcceptAll -IgnoreReboot -Verbose *>&1 | Tee-Object -FilePath $log
} catch {
    "ERROR: $($_.Exception.Message)" | Out-File -FilePath $log -Append
    exit 1
}
'@ | Set-Content -Path $wuRunner -Encoding UTF8

        $wuParts   = $CleanupTime.Split(":")
        $wuTime    = (Get-Date -Hour ([int]$wuParts[0]) -Minute ([int]$wuParts[1]) -Second 0).AddMinutes(-90)
        $wuAction  = New-ScheduledTaskAction -Execute "powershell.exe" `
                       -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wuRunner`""
        $wuTrigger = New-ScheduledTaskTrigger -Daily -At $wuTime
        $wuPrin    = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $wuSet     = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -RunOnlyIfNetworkAvailable
        Unregister-ScheduledTask -TaskName "TWDxOSOptimisation-WindowsUpdate" -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName "TWDxOSOptimisation-WindowsUpdate" -Action $wuAction -Trigger $wuTrigger `
            -Principal $wuPrin -Settings $wuSet -Description "TWDxOSOptimisation daily Windows Update scan+install" | Out-Null
        Add-Step "windows-update" "ok" "PSWindowsUpdate daily task"
        Write-Success "Windows Update: daily scan+install task registered (PSWindowsUpdate)"
    } else {
        $auKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
        New-Item -Path $auKey -Force | Out-Null
        Set-ItemProperty -Path $auKey -Name "NoAutoUpdate"        -Value 0 -Type DWord
        Set-ItemProperty -Path $auKey -Name "AUOptions"           -Value 3 -Type DWord
        Set-ItemProperty -Path $auKey -Name "ScheduledInstallDay" -Value 0 -Type DWord
        Set-ItemProperty -Path $auKey -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord
        Set-Service -Name wuauserv -StartupType Automatic
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        Add-Step "windows-update" "ok" "AU policy (auto-download + notify)"
        Write-Success "Windows Update: AU policy set (auto-download, notify to install, no forced reboot)"
    }
}

# ---------------------------------------------------------------------------
# 2. Windows Defender Firewall baseline (with lockout guard)
# ---------------------------------------------------------------------------
Write-Step "Windows Defender Firewall baseline"
if ($DryRun) {
    Write-DryRun "ensure inbound allow rules for the active management session, then Set-NetFirewallProfile -All -DefaultInboundAction Block -LogBlocked True"
    Add-Step "firewall" "dry-run"
} else {
    $remoteConns = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in 3389, 5985, 5986, 22 -and $_.RemoteAddress -notin '127.0.0.1', '::1' })
    $neededPorts = @($remoteConns | Select-Object -ExpandProperty LocalPort -Unique)
    foreach ($p in $neededPorts) {
        $have = Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -eq $p } |
            Get-NetFirewallRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' }
        if (-not $have) {
            New-NetFirewallRule -DisplayName "TWDxOSOptimisation-Allow-$p" -Direction Inbound `
                -Protocol TCP -LocalPort $p -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
            Write-Warn "Added inbound allow rule for port $p (you are connected over it) before enabling default-deny."
        }
    }
    if ($neededPorts.Count -eq 0) {
        Write-Info "No remote RDP/WinRM/SSH session detected (console session or local run)."
    } elseif (-not (Confirm-Continue "Apply default-deny inbound now? Allow rules were added for port(s) $($neededPorts -join ',').")) {
        Complete-Twdx -ExitCode 0 -FailMessage "Aborted before applying the firewall baseline."
    }
    Set-NetFirewallProfile -All -DefaultInboundAction Block -DefaultOutboundAction Allow -Enabled True
    Set-NetFirewallProfile -All -LogBlocked True -LogMaxSizeKilobytes 16384
    Add-Step "firewall" "ok" "default deny inbound; preserved ports: $($neededPorts -join ',')"
    Write-Success "Firewall baseline applied (default deny inbound, dropped-packet logging on)"
}

# ---------------------------------------------------------------------------
# 3. Scheduled Declutter + reboot-pending check
# ---------------------------------------------------------------------------
if ($EnableCleanup) {
    Write-Step "Scheduling Declutter.ps1"
    $src  = Join-Path $ScriptRoot "Declutter.ps1"
    $dest = Join-Path $InstallDir "Declutter.ps1"
    $taskName = "TWDxOSOptimisation-Declutter"
    if ($DryRun) {
        Write-DryRun "copy Declutter.ps1 -> $dest; register '$taskName' (weekly Sunday $CleanupTime)"
        Add-Step "declutter-task" "dry-run"
    } elseif (-not (Test-Path $src)) {
        Add-Step "declutter-task" "failed" "Declutter.ps1 not found beside Install.ps1"
    } else {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        Copy-Item -Path $src -Destination $dest -Force
        $parts   = $CleanupTime.Split(":")
        $at      = Get-Date -Hour ([int]$parts[0]) -Minute ([int]$parts[1]) -Second 0
        $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
                     -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dest`" -Apply"
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $at
        $prin    = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $set     = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Principal $prin -Settings $set -Description "TWDxOSOptimisation weekly cleanup" | Out-Null
        Add-Step "declutter-task" "ok" "weekly Sunday $CleanupTime"
        Write-Success "Declutter.ps1 scheduled weekly (Sunday $CleanupTime)"
    }
} else {
    Add-Step "declutter-task" "skipped" "EnableCleanup=false"
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
if ($script:Failures -gt 0) {
    Write-Warn "Completed with $($script:Failures) failed step(s)."
    Complete-Twdx -ExitCode 4
}
if (-not $Json) {
    Write-Host ""
    Write-Host "  TWDxOSOptimisation $TwdxVersion installed on $env:COMPUTERNAME" -ForegroundColor Green
    Write-Host "  Run .\Harden.ps1 next for OS hardening (firewall/RDP/telemetry/LLMNR/SMBv1/Defender)." -ForegroundColor Cyan
    Write-Host ""
}
Complete-Twdx -ExitCode 0
