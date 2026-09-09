<#
.SYNOPSIS
    TWDxOSOptimisation - Windows disk cleanup / optimization (v2.0.0)

.DESCRIPTION
    Reports (and with -Apply, clears): stale temp files, the Windows Update
    download cache, the component store (DISM), and old Windows.old /
    "Previous Installations" via a self-seeded Disk Cleanup profile (no
    interactive /sageset step required). Also checks reboot-pending state.
    Default mode is REPORT ONLY.

.PARAMETER Apply    Actually perform the cleanup steps.
.PARAMETER DryRun   Alias for the default (report only); accepted for symmetry.
.PARAMETER Json     Emit a single-line JSON result object to stdout.

.NOTES
    Tested: Windows Server 2022, Windows 11 - x64 + arm64
    Exit codes: 0 ok, 4 partial
    License: MIT
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Apply,
    [switch]$DryRun,
    [switch]$Json
)

$ErrorActionPreference = "Continue"
$TwdxVersion = "2.0.0"
$LogDir = "$env:ProgramData\TWDxOSOptimisation\Logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "declutter-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$ApplyChanges = $Apply -and -not $DryRun
$script:Actions = 0
$script:Failures = 0

function Write-DeclutterLog {
    param([string]$Message)
    $line = "$(Get-Date -Format 'o')  $Message"
    if (-not $Json) { Write-Host $line }
    Add-Content -Path $LogFile -Value $line
}

Write-DeclutterLog "TWDxOSOptimisation Declutter v$TwdxVersion"
Write-DeclutterLog "Mode: $(if ($ApplyChanges) { 'APPLY' } else { 'DRY-RUN report only' })"
Write-DeclutterLog "Log file: $LogFile"

# ---------------------------------------------------------------------------
# 1. Temp files (system + all user profiles)
# ---------------------------------------------------------------------------
Write-DeclutterLog "`n--- Temp files ---"
$tempPaths = @("$env:WINDIR\Temp")
Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $t = Join-Path $_.FullName "AppData\Local\Temp"
    if (Test-Path $t) { $tempPaths += $t }
}
foreach ($path in ($tempPaths | Select-Object -Unique)) {
    $items = Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-10) }
    $sizeMB = [math]::Round(((($items | Measure-Object -Property Length -Sum).Sum) / 1MB), 1)
    Write-DeclutterLog "$path : $($items.Count) files older than 10 days (~$sizeMB MB)"
    if ($ApplyChanges) {
        $items | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-DeclutterLog "[ACTION] Cleared ~$sizeMB MB of stale temp files from $path"
        $script:Actions++
    } else {
        Write-DeclutterLog "(dry-run) would remove $($items.Count) files from $path"
    }
}

# ---------------------------------------------------------------------------
# 2. Windows Update download cache
# ---------------------------------------------------------------------------
Write-DeclutterLog "`n--- Windows Update cache ---"
$wuCache = "$env:WINDIR\SoftwareDistribution\Download"
if (Test-Path $wuCache) {
    $cacheSizeMB = [math]::Round(((Get-ChildItem -Path $wuCache -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum / 1MB), 1)
    Write-DeclutterLog "Windows Update cache size: ~$cacheSizeMB MB"
    if ($ApplyChanges) {
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $wuCache -Recurse -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        Write-DeclutterLog "[ACTION] Cleared Windows Update download cache (~$cacheSizeMB MB)"
        $script:Actions++
    } else {
        Write-DeclutterLog "(dry-run) would stop wuauserv, clear $wuCache, restart wuauserv"
    }
}

# ---------------------------------------------------------------------------
# 3. Component store (DISM) + Windows.old via a self-seeded cleanmgr profile
# ---------------------------------------------------------------------------
Write-DeclutterLog "`n--- Component store / Windows.old ---"
if ($ApplyChanges) {
    try {
        & Dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null
        Write-DeclutterLog "[ACTION] DISM /StartComponentCleanup completed"
        $script:Actions++
    } catch {
        Write-DeclutterLog "DISM cleanup failed: $($_.Exception.Message)"
        $script:Failures++
    }
} else {
    Write-DeclutterLog "(dry-run) would run: Dism.exe /Online /Cleanup-Image /StartComponentCleanup"
}

$hasWindowsOld = Test-Path "$env:SystemDrive\Windows.old"
if ($hasWindowsOld) {
    Write-DeclutterLog "Windows.old present (leftover from a previous Windows upgrade)."
}
if ($ApplyChanges -and $PSCmdlet.ShouldProcess("Disk Cleanup handlers", "Run cleanmgr with a self-seeded profile")) {
    # Seed StateFlags for the handlers we want, then run that tag non-interactively.
    $vcRoot = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
    $wanted = @("Update Cleanup", "Previous Installations", "Temporary Files",
                "Delivery Optimization Files", "Windows Defender", "Windows Error Reporting Files",
                "Downloaded Program Files", "Thumbnail Cache", "Recycle Bin")
    $tag = 4242
    $sf = "StateFlags{0:D4}" -f $tag
    Get-ChildItem $vcRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $leaf = Split-Path $_.PSChildName -Leaf
        $val = if ($wanted -contains $leaf) { 2 } else { 0 }
        Set-ItemProperty -Path $_.PSPath -Name $sf -Value $val -Type DWord -ErrorAction SilentlyContinue
    }
    try {
        Start-Process -FilePath "$env:WINDIR\System32\cleanmgr.exe" -ArgumentList "/sagerun:$tag" -Wait -WindowStyle Hidden -ErrorAction Stop
        Write-DeclutterLog "[ACTION] Ran Disk Cleanup (self-seeded profile: Update Cleanup, Previous Installations, temp, DO cache, WER, recycle bin)"
        $script:Actions++
    } catch {
        Write-DeclutterLog "cleanmgr run failed: $($_.Exception.Message)"
        $script:Failures++
    }
} elseif (-not $ApplyChanges) {
    Write-DeclutterLog "(dry-run) would seed a cleanmgr profile and run it (removes Windows.old / Previous Installations, WU cleanup, WER, DO cache)"
}

# ---------------------------------------------------------------------------
# 4. Reboot-pending check
# ---------------------------------------------------------------------------
Write-DeclutterLog "`n--- Reboot-pending check ---"
$rebootPending = $false
$rebootKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
    "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
)
foreach ($key in $rebootKeys) {
    if (Test-Path $key) { $rebootPending = $true }
}
if ($rebootPending) {
    Write-DeclutterLog "*** REBOOT REQUIRED - a pending update needs a restart to complete ***"
} else {
    Write-DeclutterLog "No reboot currently required."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-DeclutterLog "`n--- Summary ---"
Write-DeclutterLog "Mode: $(if ($ApplyChanges) { 'APPLY' } else { 'DRY-RUN' })  Actions: $($script:Actions)  Failures: $($script:Failures)"
if (-not $ApplyChanges) { Write-DeclutterLog "Re-run with -Apply to perform these steps." }

$exitCode = if ($script:Failures -gt 0) { 4 } else { 0 }
if ($Json) {
    [pscustomobject]@{
        tool = "twdxos"; platform = "windows"; script = "declutter"; version = $TwdxVersion
        mode = $(if ($ApplyChanges) { "apply" } else { "dry-run" })
        actions_taken = $script:Actions; failures = $script:Failures
        reboot_required = $rebootPending; windows_old_present = $hasWindowsOld
        exit_code = $exitCode; log_file = $LogFile; timestamp = (Get-Date).ToString("o")
    } | ConvertTo-Json -Depth 4 -Compress
}
exit $exitCode
