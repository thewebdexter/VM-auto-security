# TWDxOSOptimisation — Windows — Claude Context

Hands-off maintenance toolkit for Windows Server/Desktop. Pure PowerShell
(no external build tooling, no compiled code, no .NET project files).

This folder is self-contained. It does not share code with any other
platform folder in this repo (see the root `CLAUDE.md` for the project-wide
philosophy) — edit it without needing to understand `linux-debian`,
`linux-rhel`, or `macos`. It also has no WP-CLI module — see
`Modules/README.md` for the reasoning, which is a deliberate, documented
omission rather than a gap.

---

## Repository Layout (this folder)

```
platforms/windows/
├── README.md                                # User-facing docs
├── CLAUDE.md                                 # This file
├── Install.ps1                                # PSWindowsUpdate setup, firewall baseline, schedules Declutter.ps1
├── Uninstall.ps1                              # Removes scheduled task, installed files, SSH firewall rule
├── Harden.ps1                                  # Firewall hardening, RDP NLA, optional OpenSSH sshd_config edit
├── Declutter.ps1                               # Temp/WU-cache cleanup, DISM component cleanup, reboot-pending check
├── PSScriptAnalyzerSettings.psd1                # Lint config (excludes PSAvoidUsingWriteHost — see below)
├── Configs/
│   └── ScheduledTask-Declutter.xml.tpl         # Reference-only Task Scheduler XML (Install.ps1 doesn't import this)
└── Modules/
    └── README.md                               # Documents why there's no WP-CLI module here
```

## File Map

| File | Purpose | Key symbols |
|---|---|---|
| `Install.ps1` | Entry point. Params: `-DryRun` `-EnableCleanup` `-CleanupTime` (HH:mm). Installs `PSWindowsUpdate` (best-effort), sets the Defender Firewall baseline, copies `Declutter.ps1` to `C:\Program Files\TWDxOSOptimisation\` and registers the `TWDxOSOptimisation-Declutter` Scheduled Task via `Register-ScheduledTask` | `Write-Info`/`Write-Success`/`Write-Warn`/`Write-ErrorX`/`Write-Step`/`Write-DryRun` logging palette (PowerShell equivalent of the Bash platforms' `info`/`success`/`warn`/`error`) |
| `Uninstall.ps1` | Unregisters the scheduled task, removes the install directory, removes the `TWDxOSOptimisation-SSH` firewall rule, optionally restores `sshd_config` from backup and reverts the firewall default-inbound policy | — |
| `Harden.ps1` | Params: `-DryRun` `-EnableRdpHardening` `-SshPort`. Firewall default-deny inbound + logging; RDP NLA via `HKLM:...\Terminal Server\WinStations\RDP-Tcp\UserAuthentication`; OpenSSH Server hardening ONLY if `Get-WindowsCapability OpenSSH.Server*` reports Installed | Backup-before-mutate pattern for `sshd_config` (`$sshdConfigPath.twdxos-backup`) — the Windows-specific exception to the other platforms' drop-in convention, since Windows' OpenSSH build has no `Include` directory mechanism |
| `Declutter.ps1` | `[CmdletBinding(SupportsShouldProcess=$true)]`, params `-Apply` `-DryRun`. Cleans `$env:TEMP`/`$env:WINDIR\Temp` (>10 days old), Windows Update download cache (stops/restarts `wuauserv`), runs `Dism.exe /Online /Cleanup-Image /StartComponentCleanup`, checks two registry keys for reboot-pending state | Logs to `$env:ProgramData\TWDxOSOptimisation\Logs\declutter-<timestamp>.log` |
| `Configs/ScheduledTask-Declutter.xml.tpl` | Placeholders: `__CLEANUP_HOUR__` `__CLEANUP_MINUTE__` `__SCRIPT_PATH__`. Reference only — `Install.ps1` builds the task programmatically, not by importing this file | — |
| `PSScriptAnalyzerSettings.psd1` | Excludes `PSAvoidUsingWriteHost` repo-wide for this folder — these are interactive admin CLI scripts where colored `Write-Host` output is the intended UX (the PowerShell equivalent of the Bash platforms' colored `echo` palette), not an oversight. Used by both the CI job and the local lint command below | — |

## Conventions (PowerShell equivalents of the Bash platforms' conventions)

| Convention | Bash equivalent | Detail |
|---|---|---|
| Dry-run | `DRY_RUN`/`--dry-run` | `-DryRun` switch parameter on every script; `Declutter.ps1` additionally uses native `[CmdletBinding(SupportsShouldProcess)]` + `$PSCmdlet.ShouldProcess()` for the one step that maps to a cmdlet supporting `-WhatIf` |
| Logging palette | `info`/`success`/`warn`/`error`/`step`/`dry_run` functions | `Write-Info`/`Write-Success`/`Write-Warn`/`Write-ErrorX`/`Write-Step`/`Write-DryRun` — same five-plus-one shape, PowerShell-cased |
| Idempotency | `install.sh`/`harden.sh` safe to re-run | `Install.ps1`/`Harden.ps1` are also safe to re-run — `Register-ScheduledTask`/`Unregister-ScheduledTask` first, firewall rules created with `-ErrorAction SilentlyContinue` guards |
| Drop-in style configs | `/etc/<thing>.d/99-twdxos-hardening.conf` | **Deviation, not followed**: Windows has no equivalent mechanism for `sshd_config`, so `Harden.ps1` backs the file up once and edits it directly instead — documented explicitly in this file and in `Harden.ps1`'s own comment block so it isn't mistaken for an oversight |
| Checksum-verified fetch | `FILE_CHECKSUMS`/`fetch_verified()` in the Bash platforms' `install.sh` | **Not used here** — there's no curl-piped-into-sudo-bash install pattern assumed for Windows in this pass; `Install.ps1` operates on files already present in the cloned/downloaded folder next to it. If a Windows one-liner install (`irm ... | iex`) needs the same tamper-evidence guarantee later, that would be the natural place to add it |

## Common Change Recipes

| Goal | Files to touch |
|---|---|
| Change the declutter schedule | Edit `-CleanupTime` handling in `Install.ps1`; update `Configs/ScheduledTask-Declutter.xml.tpl` to match for documentation parity |
| Add a new firewall rule | Edit the relevant section in `Install.ps1` or `Harden.ps1`; add a matching removal in `Uninstall.ps1` |
| Add a new hardening step | Add a numbered section to `Harden.ps1` following the existing `Write-Step`/`-DryRun` branch pattern |
| Add a CI rule | Extend `.github/workflows/powershell-lint.yml` (PSScriptAnalyzer, scoped to `platforms/windows/`) |

## Quick Commands

```powershell
# Lint locally (matches CI - PSScriptAnalyzer)
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning,Error -Settings PSScriptAnalyzerSettings.psd1

# Preview without applying
.\Install.ps1 -DryRun
.\Harden.ps1 -DryRun
.\Declutter.ps1
.\Harden.ps1 -Json -NonInteractive   # machine-readable, no prompts
```

## v2.0.0 deltas

- **Enterprise contract**: every script takes `-Json` (single-line JSON on
  stdout via `Complete-Twdx`), `-NonInteractive`, `-DryRun`. Exit codes
  `0` ok / `2` usage / `3` preflight / `4` partial. `$script:Steps` list +
  `Add-Step name status [detail]`.
- **`Install.ps1`**: "Windows Update automation" is now a *real* daily
  `TWDxOSOptimisation-WindowsUpdate` scheduled task (PSWindowsUpdate
  `Get-WindowsUpdate -Install`, or an AU registry-policy fallback). Firewall
  baseline has a **lockout guard**: it reads `Get-NetTCPConnection` for an
  established RDP/WinRM/SSH session and adds an inbound allow rule for that
  port *before* setting `-DefaultInboundAction Block`.
- **`Harden.ps1`**: same firewall guard + `-AllowInboundLockout` override;
  new sections — telemetry (`AllowTelemetry` + disable `DiagTrack`), LLMNR
  (`EnableMulticast=0`) + NetBIOS-over-TCP/IP (`NetbiosOptions=2` per
  interface), SMBv1 removal, Defender (`Set-MpPreference`; Tamper Protection
  reported only), SmartScreen, AutoRun/AutoPlay. `sshd_config` edits are now
  inserted **before the first `Match` block**. Helper `Write-RegistryValue`
  (named `Write-*`, not `Set-*`, to satisfy
  `PSUseShouldProcessForStateChangingFunctions`).
- **`Declutter.ps1`**: `Windows.old` removal via a **self-seeded `cleanmgr`
  profile** (`StateFlags4242`) + `DISM /StartComponentCleanup` — no manual
  `/sageset` needed. Cleans every user profile's `%LocalAppData%\Temp`, not
  just the caller's. `-Json`.
- **`Uninstall.ps1`**: `-NonInteractive` / `-Purge` / `-Json`; removes both
  scheduled tasks and all `TWDxOSOptimisation-*` firewall rules.
- **PSSA gotchas**: script `param()` vars referenced *only* inside a
  `function` trip `PSReviewUnusedParameter` — reference them once in the main
  body. State-changing verbs (`Set/New/Remove/Stop/...`) on custom functions
  trip `PSUseShouldProcessForStateChangingFunctions`.
