# Changelog

All notable changes to TWDxOSOptimisation. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/). Dates are ISO-8601.

---

## [2.0.0] — 2026-09-09 — "Enterprise-ready"

A large hardening + enterprise-readiness pass across **all four platform
folders** (`linux-debian`, `linux-rhel`, `macos`, `windows`). Every platform
is still independently maintained — nothing is shared between folders.

### ⚠️ Behaviour changes (read before upgrading an existing host)

| Area | Old default | New default (v2.0.0) | Why |
|---|---|---|---|
| **WordPress module** (Linux) | WP-CLI + WP cron installed on every host | **Only when `WP_PATH` is set** and valid | It's an optional module, not the centrepiece. Non-WP hosts no longer get a failing cron job. Matches how `macos` already behaved. |
| **unattended-upgrades** (Debian) | all pockets incl. `-updates`, `DevRelease auto` | **security pocket only**, `DevRelease false` | A hands-off *security* tool should not push feature/bugfix updates unattended. Re-add `${distro_codename}-updates` to `Allowed-Origins` to restore. |
| **dnf-automatic** (RHEL) | `upgrade_type = default` | **`upgrade_type = security`** | Same reasoning. Set back to `default` for all updates. |
| **needrestart** (Linux) | `$nrconf{restart} = 'a'` (auto-restart every service) | **`'l'` (list only)** | Stops silent mid-request restarts of MariaDB/PHP-FPM/nginx during unattended upgrades. Set to `'a'` to restore. |
| **fail2ban `ignoreip`** (Linux) | `127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16` | **`127.0.0.1/8 ::1`** | Whitelisting all RFC1918 trusts the whole internet when the host is behind a NAT/LB/tunnel, and every lateral host on a shared VPC. Add *your* management CIDRs to `jail.local`. |
| **auto-reboot** (Debian) | `unattended-upgrades` **and** `auto-reboot.timer` both rebooted | only **`auto-reboot.timer`** (u-u `Automatic-Reboot "false"`) | One mechanism, honours `REBOOT_TIME` + `Persistent`. |
| **auto-reboot grace** (Linux) | `shutdown -r +1` | **`shutdown -r +5`** + `wall` message | Gives an operator on the box time to `shutdown -c`. |
| **`harden.sh` with no SSH key + no TTY** | proceeded, disabling password auth (lockout) | **aborts** unless `ALLOW_PASSWORD_LOCKOUT=true` | Fail closed. |
| **Windows firewall default-deny** | flipped with no check | **lockout guard**: adds an inbound allow rule for the RDP/WinRM/SSH port you're connected on first | Stops remote self-lockout. |
| **Windows "Windows Update automation"** | installed `PSWindowsUpdate`, scheduled nothing | **real daily scan+install task** (or AU policy fallback) | The old step was a no-op. |
| **Windows `Declutter.ps1` Windows.old** | `cleanmgr /sagerun:1` (needed a manual `/sageset:1`) | **self-seeded cleanmgr profile** + `DISM /StartComponentCleanup` | Actually works unattended. |
| **macOS `declutter.sh --cron`** | auto-removed "orphan" LaunchDaemons; auto-ran `brew upgrade --formula`, `brew autoremove`, `mas upgrade` | **report-only** for orphans; those brew/mas steps auto-decline in `--cron` (still offered interactively) | Unattended third-party software changes are too risky. |
| **macOS WP module lock/log** | `/tmp/wp-auto-update.{lock,log}` | under `$TMPDIR` / `~/Library/Logs/macos-declutter/` | No predictable path in shared `/tmp` (symlink-follow). |

### Added

- **Enterprise CLI contract** on every script:
  - `--json` — single-line JSON result object on stdout (human logs go to
    stderr / the verbose stream). Stable schema: `tool, platform, script,
    version, result, dry_run, failures, exit_code, host, timestamp, steps[]`.
  - `--offline` / `OFFLINE=true` — no network fetches; use files bundled beside
    the script (`BUNDLE_DIR`). Honours `CURL_OPTS` and the standard
    `HTTP(S)_PROXY` / `NO_PROXY` env for the online path.
  - `--non-interactive` / `NON_INTERACTIVE=true` — never prompt; fail closed on
    any unresolved decision.
  - `--strict` — `--non-interactive` + `--require-signatures`.
  - Stable **exit codes**: `0` ok · `2` usage/config · `3` preflight ·
    `4` partial (some steps failed) · `5` integrity (checksum/signature).
- **Supply-chain: minisign signature verification** (`--require-signatures` /
  `REQUIRE_SIGNATURES=true`) in addition to SHA-256, keyed on
  `platforms/<p>/keys/twdxos-release.pub`. Best-effort by default; mandatory
  under `--strict`. See `platforms/<p>/keys/README.md`. (A real release key
  must be dropped in + files signed by the maintainer to enforce it.)
- **Ref pinning**: `--ref <tag|branch|sha>` / `TWDX_REF`. One-liners in the
  READMEs now point at a release tag; `main` prints a warning.
- **New baseline hardening** (curated, not full CIS):
  - Linux: time-sync assurance (chrony / `systemd-timesyncd`), journald
    persistence + size caps (`configs/journald-twdxos.conf`), sysctl additions
    (`arp_ignore/announce`, `ip_forward=0`, `accept_ra=0`, `perf_event_paranoid`,
    `randomize_va_space`), optional `/dev/shm` + `/tmp` mount-option hardening
    (`HARDEN_SHM` default on for `/dev/shm`; `HARDEN_TMP` opt-in), AppArmor
    (Debian) / SELinux (RHEL) status reporting, `unattended-upgrade` failure
    e-mail wired from `ADMIN_EMAIL`.
  - Windows: telemetry minimisation (`AllowTelemetry` + DiagTrack), LLMNR +
    NetBIOS-over-TCP/IP disable, SMBv1 removal, Windows Defender assertions
    (real-time / PUA / cloud; Tamper Protection reported), SmartScreen,
    AutoRun/AutoPlay disable.
- **Feature toggles** so config-managed fleets can opt out of pieces they
  centralise: `ENABLE_UNATTENDED_UPGRADES`, `ENABLE_FAIL2BAN`,
  `ENABLE_NEEDRESTART`, `ENABLE_AUTO_REBOOT`, `ENABLE_TIMESYNC`,
  `ENABLE_JOURNALD_TUNING` (Linux); `-EnableWindowsUpdate`, `-EnableCleanup`
  (Windows).
- `uninstall` scripts gained `--non-interactive`, `--assume-yes`, `--purge`,
  `--json` and now remove the v2 artifacts (journald drop-in, mail drop-in,
  fstab mount-hardening lines, WU task).
- `WP_CLI_PINNED_SHA512` env to enforce an exact WP-CLI digest instead of the
  TOFU upstream `.sha512` cross-check.

### Fixed

- SSH lockout guard now also recognises `AuthorizedKeysCommand`, root's
  `authorized_keys`, and `/etc/ssh/authorized_keys.d/`.
- RHEL `harden.sh`: a custom `SSH_PORT` now also removes the stock `ssh`
  service (port 22) from the firewalld default zone.
- Linux `declutter.sh`: temp cleanup no longer blindly `-delete`s by mtime —
  it prefers `systemd-tmpfiles --clean` and otherwise removes only regular
  files/symlinks, skipping sockets, `systemd-private-*`, `.X11-unix`, etc.
- Linux `declutter.sh`: log dir `0750` / files `0640` (was world-readable and
  full of host recon); running-kernel match no longer relies on fragile
  `-generic` string munging; RHEL `dnf needs-restarting` probe fixed (the old
  `command -v dnf-utils` was always false).
- `install.sh`: single cleanup trap (was stacking `trap … EXIT` and leaking
  temp files); `ADMIN_EMAIL` is validated (was written verbatim into
  `/etc/cron.d`); `curl` calls pinned to `--proto '=https' --tlsv1.2` with
  retries/timeouts.
- Windows `Harden.ps1`: `sshd_config` directives are inserted **before** the
  first `Match` block so they apply globally.
- macOS `harden.sh`: dropped the removed `spctl --master-enable` advice; added
  SIP + screen-lock reporting.

### Notes for the maintainer

- Create and push a `v2.0.0` git tag so the pinned one-liners resolve.
- To enforce signatures: generate a minisign key, replace every
  `platforms/*/keys/twdxos-release.pub`, sign each shipped file
  (`*.minisig`), commit. Until then `--require-signatures` fails closed by
  design.
