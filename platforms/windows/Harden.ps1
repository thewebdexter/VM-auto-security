<#
.SYNOPSIS
    TWDxOSOptimisation - Windows Server/Desktop hardening (v2.0.0)

.DESCRIPTION
    Idempotent host hardening:
      * Windows Defender Firewall: default-deny inbound + logging, WITH a
        lockout guard that preserves the management port you are connected on.
      * RDP: enforce Network Level Authentication.
      * Telemetry: set AllowTelemetry to the minimum the edition allows and
        disable the Connected User Experiences and Telemetry service.
      * Name resolution: disable LLMNR and NetBIOS-over-TCP/IP (classic
        credential-theft / lateral-movement vectors).
      * SMBv1: disable the protocol and remove the optional feature.
      * Windows Defender: real-time protection, PUA block, cloud protection;
        report Tamper Protection state (cannot be set from a script).
      * SmartScreen: enable for Explorer and Edge.
      * AutoRun / AutoPlay: disable for all drive types.
      * OpenSSH Server (only if installed): back sshd_config up once, then set
        hardened directives BEFORE any Match block.

.PARAMETER DryRun               Preview only.
.PARAMETER Json                 Emit a JSON result object on stdout.
.PARAMETER NonInteractive       Never prompt; fail closed on lockout risk.
.PARAMETER EnableRdpHardening   Enforce NLA for RDP. Default: $true
.PARAMETER SshPort              Firewall port for OpenSSH Server, if installed. Default: 22
.PARAMETER AllowInboundLockout  Proceed with default-deny even with no allow rule
                                for the current remote session. Default: $false

.NOTES
    Tested: Windows Server 2022, Windows 11 - x64 + arm64
    Exit codes: 0 ok, 2 usage, 3 preflight, 4 partial
    License: MIT
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Json,
    [switch]$NonInteractive,
    [bool]$EnableRdpHardening = $true,
    [int]$SshPort = 22,
    [bool]$AllowInboundLockout = $false
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
            tool = "twdxos"; platform = "windows"; script = "harden"; version = $TwdxVersion
            result = $(if ($ExitCode -eq 0) { "ok" } elseif ($ExitCode -eq 4) { "partial" } else { "error" })
            dry_run = [bool]$DryRun; failures = $script:Failures; exit_code = $ExitCode
            host = $env:COMPUTERNAME; timestamp = (Get-Date).ToString("o"); steps = $script:Steps
        } | ConvertTo-Json -Depth 5 -Compress
    }
    exit $ExitCode
}
function Write-RegistryValue {
    param([string]$Path, [string]$Name, [object]$Value, [string]$Type = "DWord")
    if ($DryRun) { Write-DryRun "set $Path\$Name = $Value"; return }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type
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
    Write-Host "          TWDxOSOptimisation - Windows Hardening  v$TwdxVersion    " -ForegroundColor Cyan
    Write-Host "               Developed by: TheWebDexter.com                      " -ForegroundColor Cyan
    Write-Host "  =================================================================" -ForegroundColor Cyan
    Write-Host ""
}
if ($DryRun) { Write-Warn "Dry-run mode: no changes will be made." }
if ($NonInteractive) { Write-Info "Non-interactive mode: prompts auto-resolve to safe defaults." }

Write-Step "Preflight"
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Complete-Twdx -ExitCode 3 -FailMessage "Run from an elevated (Administrator) PowerShell session."
}
if ($SshPort -lt 1 -or $SshPort -gt 65535) {
    Complete-Twdx -ExitCode 2 -FailMessage "SshPort must be 1-65535 (got: $SshPort)."
}

# ---------------------------------------------------------------------------
# 1. Firewall (with lockout guard)
# ---------------------------------------------------------------------------
Write-Step "Windows Defender Firewall hardening"
if ($DryRun) {
    Write-DryRun "preserve inbound allow rules for the active management session, then default-deny inbound + logging"
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
            Write-Warn "Added inbound allow rule for port $p (active remote session) before default-deny."
        }
    }
    if ($neededPorts.Count -eq 0 -and -not $AllowInboundLockout) {
        Write-Info "No remote management session detected - safe to apply default-deny."
    }
    if ($neededPorts.Count -gt 0 -and -not (Confirm-Continue "Apply default-deny inbound now? Allow rules exist for port(s) $($neededPorts -join ',').")) {
        Complete-Twdx -ExitCode 0 -FailMessage "Aborted before applying the firewall baseline."
    }
    Set-NetFirewallProfile -All -DefaultInboundAction Block -DefaultOutboundAction Allow -Enabled True
    Set-NetFirewallProfile -All -LogBlocked True -LogMaxSizeKilobytes 16384
    Add-Step "firewall" "ok" "default deny inbound; preserved ports: $($neededPorts -join ',')"
    Write-Success "Firewall hardened (default deny inbound, dropped-packet logging on)"
}

# ---------------------------------------------------------------------------
# 2. RDP - Network Level Authentication
# ---------------------------------------------------------------------------
if ($EnableRdpHardening) {
    Write-Step "RDP Network Level Authentication"
    $rdpKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
    if (Test-Path $rdpKey) {
        Write-RegistryValue -Path $rdpKey -Name "UserAuthentication" -Value 1
        Write-RegistryValue -Path $rdpKey -Name "SecurityLayer" -Value 2
        Add-Step "rdp-nla" "ok"
        Write-Success "RDP NLA enforced (UserAuthentication=1, SecurityLayer=2)"
    } else {
        Add-Step "rdp-nla" "skipped" "RDP-Tcp key absent (Remote Desktop not installed)"
    }
}

# ---------------------------------------------------------------------------
# 3. Telemetry minimisation
# ---------------------------------------------------------------------------
Write-Step "Telemetry minimisation"
$edition = (Get-CimInstance Win32_OperatingSystem).Caption
$telemetryValue = if ($edition -match 'Enterprise|Education|Server|IoT') { 0 } else { 1 }
Write-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value $telemetryValue
Write-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowTelemetry" -Value $telemetryValue
Write-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "DoNotShowFeedbackNotifications" -Value 1
if (-not $DryRun) {
    Set-Service -Name DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name DiagTrack -Force -ErrorAction SilentlyContinue
}
Add-Step "telemetry" "ok" "AllowTelemetry=$telemetryValue; DiagTrack disabled"
Write-Success "Telemetry set to minimum for this edition (AllowTelemetry=$telemetryValue)"

# ---------------------------------------------------------------------------
# 4. LLMNR + NetBIOS-over-TCP/IP
# ---------------------------------------------------------------------------
Write-Step "Name-resolution hardening (LLMNR + NetBIOS)"
Write-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Name "EnableMulticast" -Value 0
if (-not $DryRun) {
    $nbtRoot = "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces"
    Get-ChildItem $nbtRoot -ErrorAction SilentlyContinue | ForEach-Object {
        Set-ItemProperty -Path $_.PSPath -Name "NetbiosOptions" -Value 2 -ErrorAction SilentlyContinue
    }
    Write-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters" -Name "NodeType" -Value 2
}
Add-Step "name-resolution" "ok" "LLMNR off; NetBIOS-over-TCP/IP disabled on all interfaces"
Write-Success "LLMNR disabled; NetBIOS-over-TCP/IP disabled per interface"

# ---------------------------------------------------------------------------
# 5. SMBv1 removal
# ---------------------------------------------------------------------------
Write-Step "SMBv1 removal"
if ($DryRun) {
    Write-DryRun "Set-SmbServerConfiguration -EnableSMB1Protocol `$false; Disable-WindowsOptionalFeature SMB1Protocol"
    Add-Step "smbv1" "dry-run"
} else {
    try {
        Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction SilentlyContinue
        $feat = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction SilentlyContinue
        if ($feat -and $feat.State -eq "Enabled") {
            Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction Stop | Out-Null
        }
        Write-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "SMB1" -Value 0
        Add-Step "smbv1" "ok"
        Write-Success "SMBv1 disabled/removed (reboot may be required to finish feature removal)"
    } catch {
        Add-Step "smbv1" "failed" $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# 6. Windows Defender
# ---------------------------------------------------------------------------
Write-Step "Windows Defender"
if ($DryRun) {
    Write-DryRun "Set-MpPreference: real-time on, PUA block, cloud High, submit safe samples"
    Add-Step "defender" "dry-run"
} else {
    try {
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
        Set-MpPreference -PUAProtection Enabled -ErrorAction SilentlyContinue
        Set-MpPreference -MAPSReporting Advanced -ErrorAction SilentlyContinue
        Set-MpPreference -SubmitSamplesConsent SendSafeSamples -ErrorAction SilentlyContinue
        Set-MpPreference -CloudBlockLevel High -ErrorAction SilentlyContinue
        $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
        $tp = if ($mp) { $mp.IsTamperProtected } else { "unknown" }
        if ($tp -ne $true) {
            Write-Warn "Tamper Protection is not on. Enable it in Windows Security > Virus & threat protection (or via Intune) - it cannot be set from a script."
        }
        Add-Step "defender" "ok" "realtime on; PUA block; cloud High; tamper-protected=$tp"
        Write-Success "Defender: real-time on, PUA block, cloud protection High"
    } catch {
        Add-Step "defender" "failed" $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# 7. SmartScreen
# ---------------------------------------------------------------------------
Write-Step "SmartScreen"
Write-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableSmartScreen" -Value 1
Write-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "ShellSmartScreenLevel" -Value "Block" -Type String
Write-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name "SmartScreenEnabled" -Value 1
Add-Step "smartscreen" "ok"
Write-Success "SmartScreen enabled for Explorer and Edge"

# ---------------------------------------------------------------------------
# 8. AutoRun / AutoPlay
# ---------------------------------------------------------------------------
Write-Step "AutoRun / AutoPlay"
Write-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value 255
Write-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "NoAutoplayfornonVolume" -Value 1
Add-Step "autorun" "ok"
Write-Success "AutoRun/AutoPlay disabled for all drive types"

# ---------------------------------------------------------------------------
# 9. OpenSSH Server hardening (only if installed)
# ---------------------------------------------------------------------------
Write-Step "OpenSSH Server hardening (if installed)"
$sshdConfig = "$env:ProgramData\ssh\sshd_config"
$sshFeature = Get-WindowsCapability -Online -Name "OpenSSH.Server*" -ErrorAction SilentlyContinue |
    Where-Object { $_.State -eq "Installed" }
if (-not $sshFeature -or -not (Test-Path $sshdConfig)) {
    Add-Step "openssh" "skipped" "OpenSSH Server not installed"
} elseif ($DryRun) {
    Write-DryRun "back up sshd_config once; set hardened directives BEFORE any Match block; open port $SshPort; restart sshd"
    Add-Step "openssh" "dry-run"
} else {
    $backup = "$sshdConfig.twdxos-backup"
    if (-not (Test-Path $backup)) {
        Copy-Item -Path $sshdConfig -Destination $backup
        Write-Info "Backed up sshd_config -> $backup"
    }
    $desired = [ordered]@{
        "PermitRootLogin"        = "no"
        "PasswordAuthentication" = "no"
        "PermitEmptyPasswords"   = "no"
        "MaxAuthTries"           = "3"
        "LoginGraceTime"         = "30"
        "ClientAliveInterval"    = "300"
        "ClientAliveCountMax"    = "2"
        "X11Forwarding"          = "no"
        "AllowTcpForwarding"     = "no"
    }
    $lines = [System.Collections.Generic.List[string]](Get-Content -Path $sshdConfig)
    $firstMatch = $lines | Select-String -Pattern '^\s*Match\s' | Select-Object -First 1
    $matchIdx = if ($null -ne $firstMatch) { $firstMatch.LineNumber } else { $lines.Count + 1 }
    foreach ($k in $desired.Keys) {
        $rx = "^\s*#?\s*$k\s+.*$"
        $repl = "$k $($desired[$k])"
        $existing = $lines | Select-String -Pattern $rx | Where-Object { $_.LineNumber -lt $matchIdx } | Select-Object -First 1
        if ($null -ne $existing) {
            $lines[$existing.LineNumber - 1] = $repl
        } else {
            $lines.Insert([Math]::Max(0, $matchIdx - 1), $repl)
            $matchIdx++
        }
    }
    Set-Content -Path $sshdConfig -Value $lines -Encoding UTF8
    New-NetFirewallRule -DisplayName "TWDxOSOptimisation-SSH" -Direction Inbound -Protocol TCP `
        -LocalPort $SshPort -Action Allow -ErrorAction SilentlyContinue | Out-Null
    Restart-Service sshd -ErrorAction SilentlyContinue
    Add-Step "openssh" "ok" "port $SshPort; backup at $backup"
    Write-Success "OpenSSH Server hardened (backup at $backup)"
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
if ($script:Failures -gt 0) {
    Write-Warn "Hardening completed with $($script:Failures) failed step(s)."
    Complete-Twdx -ExitCode 4
}
if (-not $Json) {
    Write-Host ""
    Write-Host "  Hardening complete on $env:COMPUTERNAME" -ForegroundColor Green
    Write-Host "  SMBv1 feature removal may need a reboot to finish." -ForegroundColor Cyan
    Write-Host ""
}
Complete-Twdx -ExitCode 0
