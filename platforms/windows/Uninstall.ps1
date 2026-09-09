<#
.SYNOPSIS
    TWDxOSOptimisation - Windows Uninstaller (v2.0.0)

.DESCRIPTION
    Removes the scheduled Declutter and Windows Update tasks, the installed
    files, and the TWDxOSOptimisation firewall rules. With -Purge (or an
    interactive yes) also reverts the Defender Firewall default-inbound
    policy and restores the original sshd_config backup.

.PARAMETER DryRun          Preview only.
.PARAMETER Json            Emit a JSON result object on stdout.
.PARAMETER NonInteractive  Never prompt.
.PARAMETER Purge           Also revert firewall policy / restore sshd_config.

.NOTES
    Exit codes: 0 ok, 2 usage, 3 preflight
    License: MIT
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Json,
    [switch]$NonInteractive,
    [switch]$Purge
)

$ErrorActionPreference = "Stop"
$TwdxVersion = "2.0.0"
$script:Removed = New-Object System.Collections.Generic.List[string]

function Write-Info    { param([string]$Message) if (-not $Json) { Write-Host "[info]  $Message" -ForegroundColor Cyan } else { Write-Verbose $Message } }
function Write-Success { param([string]$Message) if (-not $Json) { Write-Host "[ ok ]  $Message" -ForegroundColor Green } else { Write-Verbose $Message } }
function Write-Warn    { param([string]$Message) if (-not $Json) { Write-Host "[warn]  $Message" -ForegroundColor Yellow } else { Write-Warning $Message } }

function Complete-Twdx {
    param([int]$ExitCode, [string]$FailMessage)
    if ($FailMessage) { Write-Host "[fail]  $FailMessage" -ForegroundColor Red }
    if ($Json) {
        [pscustomobject]@{
            tool = "twdxos"; platform = "windows"; script = "uninstall"; version = $TwdxVersion
            dry_run = [bool]$DryRun; purge = [bool]$Purge; removed = $script:Removed
            exit_code = $ExitCode; timestamp = (Get-Date).ToString("o")
        } | ConvertTo-Json -Depth 4 -Compress
    }
    exit $ExitCode
}
function Confirm-Continue {
    param([string]$Prompt)
    if ($Purge) { return $true }
    if ($NonInteractive) { return $false }
    $ans = Read-Host "  $Prompt [y/N]"
    return ($ans -match '^[Yy]$')
}
function Add-Removed { param([string]$Label) $script:Removed.Add($Label); Write-Success $Label }
function Invoke-Step { param([scriptblock]$Action) if ($DryRun) { Write-Info "[dry-run] $Action" } else { & $Action } }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Complete-Twdx -ExitCode 3 -FailMessage "Run from an elevated (Administrator) PowerShell session."
}

if ($DryRun) { Write-Warn "Dry-run mode: no changes will be made." }
if (-not $Json) {
    Write-Host ""
    Write-Host "  =================================================================" -ForegroundColor Cyan
    Write-Host "          TWDxOSOptimisation - Windows Uninstaller  v$TwdxVersion  " -ForegroundColor Cyan
    Write-Host "  =================================================================" -ForegroundColor Cyan
    Write-Host ""
}
if (-not $NonInteractive -and -not $Purge -and -not $Json) {
    $c = Read-Host "  This removes all TWDxOSOptimisation components. Continue? [y/N]"
    if ($c -notmatch '^[Yy]$') { Write-Info "Aborted."; Complete-Twdx -ExitCode 0 }
}

foreach ($taskName in @("TWDxOSOptimisation-Declutter", "TWDxOSOptimisation-WindowsUpdate")) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Invoke-Step { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
        Add-Removed "scheduled task '$taskName'"
    }
}

$InstallDir = "C:\Program Files\TWDxOSOptimisation"
if (Test-Path $InstallDir) {
    Invoke-Step { Remove-Item -Path $InstallDir -Recurse -Force }
    Add-Removed $InstallDir
}

Get-NetFirewallRule -DisplayName "TWDxOSOptimisation-*" -ErrorAction SilentlyContinue | ForEach-Object {
    Invoke-Step { Remove-NetFirewallRule -DisplayName $_.DisplayName }
    Add-Removed "firewall rule $($_.DisplayName)"
}

$sshdConfig = "$env:ProgramData\ssh\sshd_config"
$backup = "$sshdConfig.twdxos-backup"
if ((Test-Path $backup) -and (Confirm-Continue "Restore original sshd_config from backup?")) {
    Invoke-Step { Copy-Item -Path $backup -Destination $sshdConfig -Force ; Restart-Service sshd -ErrorAction SilentlyContinue }
    Add-Removed "restored sshd_config from backup"
}

if (Confirm-Continue "Revert Defender Firewall to default-allow inbound (undo hardening)?") {
    Invoke-Step { Set-NetFirewallProfile -All -DefaultInboundAction Allow }
    Add-Removed "firewall default inbound reverted to Allow"
}

Write-Info "Telemetry / LLMNR / SMBv1 / Defender / SmartScreen policy keys set by Harden.ps1 are left in place."
Write-Info "Logs remain under $env:ProgramData\TWDxOSOptimisation\Logs."
if (-not $Json) {
    Write-Host ""
    Write-Host "  TWDxOSOptimisation (Windows) has been removed." -ForegroundColor Green
    Write-Host ""
}
Complete-Twdx -ExitCode 0
