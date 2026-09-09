# TWDxOSOptimisation — macOS

Hands-off maintenance for a Mac: identifies and optionally cleans up unused Homebrew packages, third-party launch agents/daemons, leftover caches/logs, and rarely-used apps — without touching anything that's part of macOS itself. Optionally schedules this via `launchd`, and can (cautiously) apply recommended macOS software updates.

This folder is self-contained — it has no dependency on any other platform folder in this repo.

**Developed by [TheWebDexter.com](https://thewebdexter.com)**

---

## What it does

| Layer | Tool | When |
|---|---|---|
| Homebrew maintenance (`brew update`/`upgrade`/`cleanup`) | `declutter.sh` | On-demand, or weekly via launchd |
| Cache/log/trash cleanup (age-based, user-level only) | `declutter.sh` | On-demand, or weekly via launchd |
| Unused app / launch agent audit (interactive) | `declutter.sh --aggressive` | On-demand only |
| macOS software updates (optional, off by default) | `softwareupdate` (via `declutter.sh --os-updates`) | Only if explicitly enabled |
| Application Firewall + basic SSH hardening | `harden.sh` | On-demand |
| WordPress core/plugin/theme updates (optional module) | WP-CLI | Manual, or your own launchd job |

`declutter.sh` is the primary deliverable on this platform — it already existed as a complete, tested 1000+ line script before this restructure; `install.sh` and `harden.sh` wrap it with scheduling and OS hardening.

## Requirements

- macOS 26 Tahoe, Sequoia, or Sonoma (Apple Silicon or Intel)
- Admin (sudo) access for `install.sh`/`harden.sh`; `declutter.sh` itself runs as your normal user
- Homebrew 5.x recommended for full Tahoe support (`declutter.sh` checks this and warns if outdated)

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/TheWebDexterTech/TWDxOSOptimisation/v2.0.0/platforms/macos/install.sh | sudo bash
```

Run this as your normal admin user via `sudo` (not from a root shell) — the installer uses `$SUDO_USER` to figure out which user's `launchd` GUI session should own the scheduled declutter job. Every fetched file is verified against a SHA256 digest (`shasum -a 256`) and, with `--require-signatures`, a minisign signature.

### Enterprise flags (all scripts)

`--json` · `--offline` (with `BUNDLE_DIR`) · `--non-interactive` · `--require-signatures` · `--strict` · `--ref <tag|sha>`. Exit codes: `0` ok · `2` usage · `3` preflight · `4` partial · `5` integrity.

> **v2.0.0:** `declutter.sh --cron` is now report-only for orphaned launch
> agents/daemons, and no longer auto-runs `brew upgrade --formula` /
> `brew autoremove` / `mas upgrade` (still offered interactively). See
> [`CHANGELOG.md`](../../CHANGELOG.md).

## Dry-Run Mode

```bash
sudo bash install.sh --dry-run
```

## Declutter script (the main tool)

```bash
./declutter.sh                       # report only
./declutter.sh --apply               # safe cleanup (brew, caches, logs, trash)
./declutter.sh --apply --os-updates  # also install recommended macOS updates (CAUTION: may reboot)
./declutter.sh --apply --aggressive  # interactively review unused apps/launch agents/brew leaves
./declutter.sh --cron                # non-interactive safe steps only (used by the scheduled job)
```

Logs to `~/Library/Logs/macos-declutter/`. Hard exclusions (never touched): `/System/*`, anything with a `com.apple.*` bundle ID, `/Library/Apple/*`, and system launchd jobs.

## Hardening (optional)

```bash
sudo bash harden.sh [--dry-run]
```

| Layer | What it does |
|---|---|
| Application Firewall | Enables it + stealth mode via `socketfilterfw` |
| SSH daemon | Drop-in at `/etc/ssh/sshd_config.d/99-twdxos-hardening.conf` — **only applied if your macOS version's `sshd_config` actually `Include`s that directory** (Ventura+); older macOS silently skips this with a warning, since Apple's OpenSSH build historically lagged upstream `Include` support |
| FileVault / Gatekeeper / screen-lock | **Report-only** — this script never enables/disables disk encryption or Gatekeeper automatically, since those have real user-visible tradeoffs |

## Headless configuration (install.sh)

| Variable | Default | Description |
|---|---|---|
| `ENABLE_CLEANUP` | `true` | Schedule weekly `declutter.sh` via a per-user `launchd` LaunchAgent |
| `ENABLE_OS_UPDATES` | `false` | Pass `--os-updates` to the scheduled run (off by default — can trigger a reboot or, per Apple's own caveats, a major OS jump if enrolled in a beta seed) |
| `DECLUTTER_TIME` | `03:30:00` | Weekly run time (local time, Sunday) |
| `WP_PATH` | *(empty)* | Local WordPress root — leave unset to skip the optional module entirely |
| `WP_USER` | current console user | macOS user that owns the WP files |
| `DRY_RUN` | `false` | Preview without applying |

## Optional WordPress module

`modules/wp-auto-update.sh.tpl` is for local WordPress dev (MAMP, Laravel Herd, etc.) — **not** the centerpiece of this platform. `install.sh` installs it only if `WP_PATH` is set, and does not schedule it automatically; wrap it in your own `launchd` job if you want it to run on a timer.

## Uninstall

```bash
sudo bash uninstall.sh
```

## License

MIT
