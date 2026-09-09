# TWDxOSOptimisation — macOS — Claude Context

Hands-off maintenance toolkit for a Mac. Pure Bash. No build system, no
compiled code. `declutter.sh` predates the other files in this folder — it
was a complete, self-contained 1000+ line script before the multi-platform
restructure; `install.sh`/`harden.sh`/`uninstall.sh` were added to wrap it
with scheduling and OS hardening.

This folder is self-contained. It does not share code with any other
platform folder in this repo (see the root `CLAUDE.md` for the project-wide
philosophy) — edit it without needing to understand `linux-debian`,
`linux-rhel`, or `windows`.

---

## Repository Layout (this folder)

```
platforms/macos/
├── README.md                              # User-facing docs
├── CLAUDE.md                               # This file
├── install.sh                              # Schedules declutter.sh via launchd; optional WP-CLI module
├── uninstall.sh                            # Removes the LaunchAgent, declutter.sh binary, SSH drop-in
├── harden.sh                               # Application Firewall, SSH drop-in (conditional), report-only security status
├── declutter.sh                            # THE primary script — brew/cache/log/app cleanup + audit
├── configs/
│   └── com.twdxos.declutter.plist.tpl      # launchd LaunchAgent template
└── modules/
    └── wp-auto-update.sh.tpl               # Optional WP-CLI module (local dev, not scheduled by install.sh)
```

## File Map

| File | Purpose | Key symbols |
|---|---|---|
| `install.sh` | Fetches+verifies `declutter.sh` to `/usr/local/bin/twdxos-declutter.sh`, renders the LaunchAgent plist, `launchctl bootstrap`s it into the target user's `gui/<uid>` domain. Env: `ENABLE_CLEANUP` `ENABLE_OS_UPDATES` `DECLUTTER_TIME` `WP_PATH` `WP_USER` `LOG_FILE` `DRY_RUN` | `TARGET_USER`/`TARGET_UID` resolution via `$SUDO_USER` or `stat -f%Su /dev/console`, `fetch_verified()`, `FILE_CHECKSUMS` |
| `uninstall.sh` | `launchctl bootout`s and removes the LaunchAgent, removes the declutter binary, optionally removes the WP-CLI module and SSH drop-in, optionally disables the Application Firewall | — |
| `harden.sh` | Application Firewall + stealth mode; SSH drop-in **only if** `sshd_config` already `Include`s `sshd_config.d/*.conf` on the running macOS version; FileVault/Gatekeeper/screen-lock are report-only | `ENABLE_APP_FIREWALL` `ENABLE_SSH_HARDEN` |
| `declutter.sh` | The main tool — see its own header comment for the full flag/section breakdown (`--apply`/`--aggressive`/`--os-updates`/`--cron`). PID-file lock (not `flock`, unlike the Linux platforms) at `~/Library/Logs/macos-declutter/.lock`. Detects Homebrew at both `/opt/homebrew` (Apple Silicon) and `/usr/local` (Intel) | `PROTECTED` exclusions for `/System/*`, `com.apple.*` bundle IDs |
| `configs/com.twdxos.declutter.plist.tpl` | launchd LaunchAgent, `StartCalendarInterval` (weekly). Placeholders: `__SCRIPT_PATH__` `__WEEKDAY__` `__HOUR__` `__MINUTE__` `__EXTRA_ARG_ELEMENT__` (empty, or `<string>--os-updates</string>`) | — |
| `modules/wp-auto-update.sh.tpl` | Same idempotent structure as the Linux platforms' WP module, adapted to not assume `sudo -u` is required if already running as `WP_USER`. Not scheduled automatically. Placeholders: `__WP_PATH__` `__WP_USER__` `__LOG_FILE__` | — |

## Conventions (mirrors linux-debian/linux-rhel where it makes sense; deviates where macOS requires it)

| Convention | Detail |
|---|---|
| Dry-run | Same `DRY_RUN`/`--dry-run` convention as the Linux platforms. |
| Scheduling | `launchd`, not cron/systemd. A per-user **LaunchAgent** (not a LaunchDaemon) is used deliberately — `declutter.sh` reads `$HOME`-relative paths and per-user Homebrew, so it must run in the target user's `gui/<uid>` session, not as root. |
| SSH hardening | Deviates from the Linux platforms' "always write the drop-in" approach — Apple's OpenSSH build historically lagged upstream `sshd_config.d` `Include` support, so `harden.sh` checks for it first and skips with a warning if absent, rather than writing a file sshd will silently ignore. |
| Security-sensitive settings | FileVault and Gatekeeper are **never** toggled automatically by any script here — only reported. This is a deliberate deviation from the "just apply it" pattern used for firewalls/sysctls on the Linux platforms. |
| Checksum registry | `declare -A FILE_CHECKSUMS` in `install.sh`, using `shasum -a 256` instead of `sha256sum` (not present by default on macOS). Recompute after any `declutter.sh`, `configs/*.tpl`, or `modules/*.tpl` edit — the repo-wide `scripts/pre-commit.sh` hook (which runs on a Linux/CI shell) checks these using `sha256sum`, which produces identical digests to `shasum -a 256`. |

## Common Change Recipes

| Goal | Files to touch |
|---|---|
| Edit `declutter.sh` behavior | Edit `declutter.sh` directly, then recompute its checksum in `install.sh`'s `FILE_CHECKSUMS` — the repo-wide pre-commit hook blocks the commit if you forget |
| Change the declutter schedule | Edit `DECLUTTER_TIME`/`ENABLE_OS_UPDATES` handling in `install.sh`, or the `StartCalendarInterval` structure in `configs/com.twdxos.declutter.plist.tpl` |
| Add a new SSH hardening directive | Edit the heredoc in `harden.sh`'s SSH section — validated with `sshd -t` before it's kept |
| Change the WP update script | Edit `modules/wp-auto-update.sh.tpl`, then bump its checksum |

## Quick Commands

```bash
# Lint locally (matches CI)
shellcheck install.sh uninstall.sh harden.sh declutter.sh

# Preview without writing anything
sudo bash install.sh --dry-run
sudo bash harden.sh --dry-run

# Recompute shipped-file checksums (paste into FILE_CHECKSUMS)
for f in declutter.sh configs/com.twdxos.declutter.plist.tpl modules/wp-auto-update.sh.tpl; do
  printf '    ["%s"]="%s"\n' "$f" "$(shasum -a 256 "$f" | awk '{print $1}')"
done
```

## v2.0.0 deltas

- Same enterprise scaffolding as the Linux folders: `--json` / `--offline` /
  `--non-interactive` / `--require-signatures` / `--strict` / `--ref`, exit
  codes `0/2/3/4/5`, `keys/twdxos-release.pub` (placeholder). `install.sh`
  fetch verification uses `shasum -a 256` + `minisign`.
- `declutter.sh` (checksum-pinned): `--json`; `LOG_DIR` `0700` + `umask 077`;
  `--cron` is **report-only** for orphaned launch agents/daemons (was
  auto-moving them); `brew upgrade --formula` / `brew autoremove` /
  `mas upgrade` now auto-decline under `--cron` (still offered interactively).
- `harden.sh`: JSON + exit codes; App Firewall stealth; SSH drop-in only when
  `sshd_config` Includes `sshd_config.d/*`; **report-only** FileVault /
  Gatekeeper / SIP / screen-lock (dropped the removed `spctl --master-enable`
  advice).
- `modules/wp-auto-update.sh.tpl`: lock/log moved out of shared `/tmp`
  (`$TMPDIR` + per-uid name); `LOG_FILE` defaults under
  `~/Library/Logs/macos-declutter/`.
