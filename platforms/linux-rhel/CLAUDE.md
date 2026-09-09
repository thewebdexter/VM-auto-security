# TWDxOSOptimisation — Linux (RHEL/Fedora/CentOS) — Claude Context

Hands-off maintenance toolkit for headless servers on the RHEL family
(RHEL, CentOS Stream, Rocky Linux, AlmaLinux, Fedora). Pure Bash. No build
system, no package manager beyond `dnf`, no compiled code.

This folder is self-contained. It does not share code with any other
platform folder in this repo (see the root `CLAUDE.md` for the project-wide
philosophy) — edit it without needing to understand `linux-debian`, `macos`,
or `windows`.

---

## Repository Layout (this folder)

```
platforms/linux-rhel/
├── README.md                   # User-facing docs for this platform
├── CLAUDE.md                   # This file
├── install.sh                  # Main installer (idempotent, interactive + headless)
├── uninstall.sh                # Full teardown + optional SSH/firewalld/sysctl rollback
├── harden.sh                   # Standalone OS hardening (SSH/sysctl/firewalld)
├── declutter.sh                # dnf/rpm-based cleanup & audit script
├── configs/                    # Files fetched + checksum-verified by install.sh
│   ├── automatic.conf          # dnf-automatic policy
│   ├── needrestart.conf
│   ├── auto-reboot.service
│   ├── auto-reboot.timer.tpl
│   └── fail2ban-jail.local
└── modules/
    └── wp-auto-update.sh.tpl   # Optional WP-CLI auto-update module (not the centerpiece)
```

## File Map (with anchors)

| File | Purpose | Key symbols |
|---|---|---|
| `install.sh` | Main installer | `show_help`, `FILE_CHECKSUMS` array, `validate_*` helpers, `fetch_verified()`. Env: `WP_PATH` `WP_USER` `REBOOT_TIME` `LOG_FILE` `CRON_SCHEDULE` `ENABLE_CLEANUP` `ADMIN_EMAIL` `DRY_RUN` |
| `uninstall.sh` | Teardown — removes cron, timer, scripts, logrotate, fail2ban jail, SSH drop-in, sysctl drop-in, disables dnf-automatic timer. Prompts for WP-CLI / firewalld removal | `info`/`success`/`warn`/`error` helpers |
| `harden.sh` | OS hardening | `show_help`, `validate_port`, `validate_bool`. `SSH_DROPIN` → `/etc/ssh/sshd_config.d/99-twdxos-hardening.conf`. `SYSCTL_CONF` → `/etc/sysctl.d/99-twdxos-hardening.conf`. Env: `SSH_PORT` `ENABLE_FIREWALLD` `OPEN_HTTP` `OPEN_HTTPS` `DRY_RUN` |
| `declutter.sh` | dnf-based cleanup/audit, mirrors `linux-debian/declutter.sh`'s flag conventions (`--apply`/`--aggressive`/`--cron`) but uses `dnf`/`rpm`/`dnf needs-restarting -r` instead of `apt`/`dpkg`/`/var/run/reboot-required` | `PROTECTED_SERVICES_REGEX` (sshd/NetworkManager/firewalld/dnf-automatic/crond/…) |
| `modules/wp-auto-update.sh.tpl` | Per-host WP update script (optional module) — same idempotent structure as the Debian platform's, default `WP_USER=apache`. Placeholders: `__WP_PATH__` `__WP_USER__` `__LOG_FILE__` |
| `configs/automatic.conf` | dnf-automatic config — `apply_updates=yes`, `download_updates=yes`, `emit_via=stdio` (replaces Debian's `50unattended-upgrades`+`20auto-upgrades` pair) | — |
| `configs/auto-reboot.service` | `oneshot` — runs `dnf needs-restarting -r` inline via `ExecStart=/bin/bash -c '...'` (no reboot-required flag file exists on RHEL family, unlike Debian) | — |
| `configs/auto-reboot.timer.tpl` | systemd timer, identical to the Debian platform's (`OnCalendar=*-*-* __REBOOT_TIME__`) | Placeholder: `__REBOOT_TIME__` |
| `configs/needrestart.conf` | needrestart config from EPEL — `override_rc` list tuned for RHEL-family service names (`firewalld`, `dnf-automatic`, `crond`, `libvirtd`, `podman`) | — |
| `configs/fail2ban-jail.local` | Same jail tuning as Debian, but `banaction = firewallcmd-rich-rules` (firewalld backend, not nftables-multiport) | — |

## Dependency Graph

```
install.sh
  ├── dnf install epel-release              (RHEL/CentOS/Rocky/Alma only — Fedora skips)
  ├── fetch_verified  configs/automatic.conf       → /etc/dnf/automatic.conf
  ├── fetch_verified  configs/fail2ban-jail.local  → /etc/fail2ban/jail.local
  ├── fetch_verified  configs/needrestart.conf     → /etc/needrestart/needrestart.conf
  ├── fetch_verified  configs/auto-reboot.service  → /etc/systemd/system/auto-reboot.service
  ├── fetch_verified  configs/auto-reboot.timer.tpl → /etc/systemd/system/auto-reboot.timer
  │     (sed: __REBOOT_TIME__ → $REBOOT_TIME)
  ├── fetch_verified  modules/wp-auto-update.sh.tpl → /usr/local/bin/wp-auto-update.sh
  │     (sed: __WP_PATH__, __WP_USER__, __LOG_FILE__)
  ├── curl + sha512   wp-cli.phar                   → /usr/local/bin/wp     (skipped if `wp` already on PATH)
  ├── inline heredoc                                 → /usr/local/bin/vm-system-cleanup.sh  (only if ENABLE_CLEANUP=true)
  ├── inline heredoc                                 → /etc/logrotate.d/twdxos
  ├── systemctl enable --now dnf-automatic-install.timer
  └── generated                                      → /etc/cron.d/twdxos
        ├── WP update line     uses $CRON_SCHEDULE
        └── Cleanup line       forces minute "30" of the same hour/day to avoid overlap

harden.sh   — standalone, no install.sh dependency
  ├── generates → /etc/ssh/sshd_config.d/99-twdxos-hardening.conf  (validated with `sshd -t` before reload)
  ├── generates → /etc/sysctl.d/99-twdxos-hardening.conf           (applied via `sysctl --system`)
  └── firewalld → opens $SSH_PORT + 80/443 per flags, default deny otherwise

uninstall.sh        — interactive, reverses install.sh + optionally harden.sh
  removes (always): /etc/cron.d/twdxos · /etc/systemd/system/auto-reboot.{service,timer}
                   · dnf-automatic-install.timer (disabled) · /usr/local/bin/{wp-auto-update.sh,vm-system-cleanup.sh}
                   · /var/lock/wp-auto-update.lock · /etc/logrotate.d/{twdxos,vm-auto-security}
                   · /etc/sysctl.d/99-twdxos-hardening.conf · /etc/ssh/sshd_config.d/99-twdxos-hardening.conf
  prompts for:     WP-CLI removal · fail2ban jail removal · disable fail2ban · disable firewalld
```

## Conventions (mirrors linux-debian, adapted per-tool)

| Convention | Detail |
|---|---|
| Dry-run | `DRY_RUN="${DRY_RUN:-false}"`, flags `--dry-run`/`--check`. Every side-effect guarded the same way as the Debian platform. |
| Idempotency | `install.sh` and `harden.sh` are both safe to re-run. |
| SELinux | Never changed by any script here. If Enforcing mode blocks a step, the scripts warn and point at `audit2why`/`restorecon` rather than touching `setenforce`. |
| EPEL | `fail2ban` and `needrestart` require EPEL on RHEL/CentOS/Rocky/AlmaLinux (not Fedora) — `install.sh` detects this via `/etc/os-release`'s `ID` field. |
| Reboot detection | No `/var/run/reboot-required` flag file exists on this family — `dnf needs-restarting -r` (from `dnf-utils`) is the equivalent signal, checked inline inside `configs/auto-reboot.service`'s `ExecStart`. |
| Checksum registry | `declare -A FILE_CHECKSUMS` in `install.sh`. Recompute with `sha256sum <file>` after any `configs/*` or `modules/*.tpl` edit — the repo-wide `scripts/pre-commit.sh` hook checks this automatically across every platform. |
| Drop-in style | New OS-level config goes to `/etc/<thing>.d/99-twdxos-hardening.conf` or `/etc/<thing>/conf.d/`, never mutates the upstream file. |

## Common Change Recipes

| Goal | Files to touch |
|---|---|
| Edit a config that ships to disk | (1) edit `configs/<file>` (2) `sha256sum configs/<file>` (3) update `FILE_CHECKSUMS["configs/<file>"]` in `install.sh` — the repo-wide pre-commit hook blocks the commit if you forget |
| Add a brand-new shipped config | (1) create `configs/<file>` (2) add `FILE_CHECKSUMS` entry (3) add a `fetch_verified` call in the matching step in `install.sh` (4) add a removal line in `uninstall.sh` (5) update the Dependency Graph above |
| Change the WP update script | edit `modules/wp-auto-update.sh.tpl`, then bump its checksum (recipe row 1) |

## Quick Commands

```bash
# Lint locally (matches CI)
shellcheck install.sh uninstall.sh harden.sh declutter.sh

# Preview an install/harden without writing anything
sudo bash install.sh --dry-run
sudo bash harden.sh --dry-run

# Recompute every shipped-file checksum (paste into FILE_CHECKSUMS)
for f in configs/automatic.conf configs/needrestart.conf configs/auto-reboot.service \
         configs/auto-reboot.timer.tpl configs/fail2ban-jail.local configs/journald-twdxos.conf \
         modules/wp-auto-update.sh.tpl; do
  printf '    ["%s"]="%s"\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"
done
```

## v2.0.0 deltas (mirrors linux-debian's scaffolding — read that folder's CLAUDE.md)

- Same `--json` / `--offline` / `--non-interactive` / `--require-signatures` /
  `--strict` / `--ref` flags, same exit-code contract, same `keys/` dir.
- New `configs/journald-twdxos.conf`; `configs/automatic.conf` →
  `upgrade_type = security`; `configs/needrestart.conf` → `'l'`;
  `configs/fail2ban-jail.local` → `ignoreip` loopback-only;
  `configs/auto-reboot.service` → `shutdown -r +5` + `wall`.
- `harden.sh`: firewalld now `--remove-service=ssh` when `SSH_PORT != 22`;
  adds `HARDEN_SHM`/`HARDEN_TMP`; reports SELinux mode (Permissive/Disabled →
  `failed` step). WP module (`install.sh`) is opt-in via `WP_PATH`.
- `declutter.sh`: `--json`; `0750/0640` log perms; `dnf needs-restarting`
  probe fixed; socket-safe `/tmp` cleanup.
- Feature toggles: `ENABLE_DNF_AUTOMATIC` `ENABLE_FAIL2BAN` `ENABLE_NEEDRESTART`
  `ENABLE_AUTO_REBOOT` `ENABLE_TIMESYNC` `ENABLE_JOURNALD_TUNING`.
