# TWDxOSOptimisation — Linux (Debian/Ubuntu) — Claude Context

Hands-off maintenance toolkit for headless servers on Ubuntu 24.04 /
Debian-family distros. Pure Bash. No build system, no package manager
beyond `apt`, no compiled code. This is the original project (formerly
`TWDxWordPressServerSecurity`), now one self-contained platform folder in
a multi-platform repo.

This folder is self-contained. It does not share code with any other
platform folder in this repo (see the root `CLAUDE.md` for the project-wide
philosophy) — edit it without needing to understand `linux-rhel`, `macos`,
or `windows`.

---

## Repository Layout (this folder)

```
platforms/linux-debian/
├── README.md                   # User-facing docs for this platform
├── CLAUDE.md                   # This file
├── install.sh                  # Main installer (idempotent, interactive + headless)
├── uninstall.sh                # Full teardown + optional SSH/UFW/sysctl rollback
├── harden.sh                   # Standalone OS hardening (SSH/sysctl/UFW)
├── declutter.sh                # apt/dpkg-based cleanup & audit script
├── configs/                    # Files fetched + checksum-verified by install.sh
│   ├── 50unattended-upgrades   # v2: security pocket only; Automatic-Reboot "false"
│   ├── 20auto-upgrades
│   ├── needrestart.conf        # v2: $nrconf{restart} = 'l' (list-only)
│   ├── auto-reboot.service     # v2: shutdown -r +5 + wall message
│   ├── auto-reboot.timer.tpl
│   ├── fail2ban-jail.local     # v2: ignoreip = loopback only
│   └── journald-twdxos.conf    # v2 NEW: persistent storage + size/retention caps
├── keys/
│   ├── twdxos-release.pub      # minisign pubkey (PLACEHOLDER until maintainer signs)
│   └── README.md
└── modules/
    └── wp-auto-update.sh.tpl   # Optional WP-CLI module — installed ONLY when WP_PATH is set
```

## Enterprise scaffolding (v2.0.0 — every .sh in this folder)

`install.sh` / `harden.sh` / `uninstall.sh` / `declutter.sh` all carry an
inlined block (not a sourced lib — `install.sh` is still `curl | bash`-safe):

| Concern | How |
|---|---|
| Flags | `--json` `--offline` `--non-interactive` `--require-signatures` `--strict` `--assume-yes` `--ref <r>` (+ env equivalents `JSON_OUTPUT` `OFFLINE` `NON_INTERACTIVE` `REQUIRE_SIGNATURES` `ASSUME_YES` `TWDX_REF`) |
| Exit codes | `EX_OK=0` `EX_USAGE=2` `EX_PREFLIGHT=3` `EX_PARTIAL=4` `EX_INTEGRITY=5` |
| JSON | `mark_step name ok\|failed\|skipped\|dry-run [detail]` → `emit_json` on exit via the single `_on_exit` EXIT trap. Human logs routed to stderr by `_out` when `--json`. |
| Offline | `fetch_verified` reads `$BUNDLE_DIR/<path>` instead of curl; needs the platform folder present. |
| Signatures | `fetch_verified` runs `minisign -V` against `keys/twdxos-release.pub` when it's real + `minisign` is on PATH; mandatory under `--require-signatures` (else SHA256-only with a warn). |
| Feature toggles | `ENABLE_UNATTENDED_UPGRADES` `ENABLE_FAIL2BAN` `ENABLE_NEEDRESTART` `ENABLE_AUTO_REBOOT` `ENABLE_TIMESYNC` `ENABLE_JOURNALD_TUNING` (all default `true`). |
| `harden.sh` extras | `HARDEN_SHM` (on) / `HARDEN_TMP` `HARDEN_TMP_NOEXEC` (off) mount hardening via `/etc/fstab` lines tagged `# twdxos-hardening`; `ALLOW_PASSWORD_LOCKOUT` for the fail-closed SSH guard. |

Lint note: SC2317 fires on any helper that ends up unused in a given script,
and on the `trap`ed `_on_exit` (carries a `# shellcheck disable=SC2317`).
Never use `A && B || C` — ShellCheck SC2015. Keep `${CURL_OPTS:-}` unquoted
with a targeted `# shellcheck disable=SC2086`.

## File Map (with anchors)

| File | Purpose | Key symbols |
|---|---|---|
| `install.sh` | Main installer | `show_help` · `FILE_CHECKSUMS` array · `validate_cron_schedule` · `validate_integer_range` · `validate_wp_path` · `validate_wp_user` · `validate_reboot_time` · `validate_log_path` · `fetch_verified()`. Env: `WP_PATH` `WP_USER` `REBOOT_TIME` `LOG_FILE` `CRON_SCHEDULE` `ENABLE_CLEANUP` `ADMIN_EMAIL` `DRY_RUN` |
| `uninstall.sh` | Teardown — removes cron, timer, scripts, logrotate, fail2ban jail, SSH drop-in, sysctl drop-in. Prompts for WP-CLI / UFW removal and legacy `sshd_config.bak` restore | `info`/`success`/`warn`/`error` |
| `harden.sh` | OS hardening | `show_help` · `validate_port` · `validate_bool` · `SSH_DROPIN` const (→ `/etc/ssh/sshd_config.d/99-twdxos-hardening.conf`) · `SYSCTL_CONF` const (→ `/etc/sysctl.d/99-twdxos-hardening.conf`). Env: `SSH_PORT` `ENABLE_UFW` `OPEN_HTTP` `OPEN_HTTPS` `DRY_RUN` |
| `declutter.sh` | apt/dpkg-based cleanup/audit — `--apply`/`--aggressive`/`--cron` flags, `PROTECTED_SERVICES_REGEX`, package-usage heuristic via `apt-mark showmanual` | Logs to `/var/log/linux-declutter/` |
| `modules/wp-auto-update.sh.tpl` | Per-host WP update script — `flock` single-instance guard, per-step `run()` wrapper, exits with failure count | Placeholders: `__WP_PATH__` `__WP_USER__` `__LOG_FILE__` |
| `configs/50unattended-upgrades` | APT policy — Allowed-Origins incl. ESM, `MailReport on-change`, `Acquire::Retries 3`, `Automatic-Reboot-Time "03:00"`, `Skip-Updates-On-Metered-Connections true` | — |
| `configs/20auto-upgrades` | APT periodic intervals (Update / Download / Autoclean / Unattended all daily) | — |
| `configs/auto-reboot.service` | `oneshot` — runs `shutdown -r +1` iff `/var/run/reboot-required` exists | `ConditionPathExists=/var/run/reboot-required` |
| `configs/auto-reboot.timer.tpl` | systemd timer (`OnCalendar=*-*-* __REBOOT_TIME__`, `Persistent=true`) | Placeholder: `__REBOOT_TIME__` |
| `configs/needrestart.conf` | needrestart: `$nrconf{restart} = 'a'`, suppresses interactive prompts | — |
| `configs/fail2ban-jail.local` | Jails: `sshd` aggressive (4 retries / 10 min → 1 h ban) and `recidive` (3 bans / 1 d → 1 w ban). Exponential `bantime.increment`. `backend = systemd`, `banaction = nftables-multiport` | — |

## Dependency Graph

```
install.sh
  ├── fetch_verified  configs/50unattended-upgrades  → /etc/apt/apt.conf.d/50unattended-upgrades
  ├── fetch_verified  configs/20auto-upgrades        → /etc/apt/apt.conf.d/20auto-upgrades
  ├── fetch_verified  configs/needrestart.conf       → /etc/needrestart/needrestart.conf
  ├── fetch_verified  configs/auto-reboot.service    → /etc/systemd/system/auto-reboot.service
  ├── fetch_verified  configs/auto-reboot.timer.tpl  → /etc/systemd/system/auto-reboot.timer
  │     (sed: __REBOOT_TIME__ → $REBOOT_TIME)
  ├── fetch_verified  configs/fail2ban-jail.local    → /etc/fail2ban/jail.local
  ├── fetch_verified  modules/wp-auto-update.sh.tpl  → /usr/local/bin/wp-auto-update.sh
  │     (sed: __WP_PATH__, __WP_USER__, __LOG_FILE__)
  ├── curl + sha512   wp-cli.phar                    → /usr/local/bin/wp     (skipped if `wp` already on PATH)
  ├── inline heredoc                                  → /usr/local/bin/vm-system-cleanup.sh  (only if ENABLE_CLEANUP=true)
  ├── inline heredoc                                  → /etc/logrotate.d/twdxos
  └── generated                                       → /etc/cron.d/twdxos
        ├── WP update line     uses $CRON_SCHEDULE
        └── Cleanup line       forces minute "30" of the same hour/day to avoid overlap

harden.sh   — standalone, no install.sh dependency
  ├── generates → /etc/ssh/sshd_config.d/99-twdxos-hardening.conf  (validated with `sshd -t` before reload)
  ├── generates → /etc/sysctl.d/99-twdxos-hardening.conf           (applied via `sysctl --system`)
  └── ufw       → IPV6=yes, default deny-in / allow-out, low logging, opens $SSH_PORT + 80/443 per flags

uninstall.sh        — interactive, reverses install.sh + optionally harden.sh
  removes (always): /etc/cron.d/twdxos · /etc/systemd/system/auto-reboot.{service,timer}
                   · /usr/local/bin/{wp-auto-update.sh,vm-system-cleanup.sh}
                   · /var/lock/wp-auto-update.lock · /etc/logrotate.d/{twdxos,vm-auto-security}
                   · /etc/sysctl.d/99-twdxos-hardening.conf · /etc/ssh/sshd_config.d/99-twdxos-hardening.conf
  prompts for:     WP-CLI removal · /etc/fail2ban/jail.local removal · disable unattended-upgrades+fail2ban
                   · restore /etc/ssh/sshd_config.bak (legacy installs only) · `ufw disable`
```

## Runtime Artifacts (post-install, on a deployed host)

Not in the repo — useful when answering triage/debugging questions.

| Path | Created by | Purpose |
|---|---|---|
| `/etc/cron.d/twdxos` | install.sh | WP update + optional cleanup cron lines |
| `/usr/local/bin/wp-auto-update.sh` | install.sh | Rendered template — runs under `flock` |
| `/usr/local/bin/vm-system-cleanup.sh` | install.sh | apt autoremove/autoclean + journal vacuum |
| `/var/lock/wp-auto-update.lock` | wp-auto-update.sh runtime | `flock` single-instance guard |
| `/var/log/wp-auto-update.log` | install.sh | mode 640, owner `root:adm` |
| `/var/log/vm-system-cleanup.log` | install.sh | mode 640, owner `root:adm` |
| `/etc/logrotate.d/twdxos` | install.sh | Weekly, rotate 4, compress |
| `/etc/systemd/system/auto-reboot.{service,timer}` | install.sh | Conditional kernel reboot |

## Conventions

| Convention | Detail |
|---|---|
| Dry-run | `DRY_RUN="${DRY_RUN:-false}"`, flags `--dry-run` / `--check`. Every side-effect guarded by `if [[ "$DRY_RUN" == "true" ]]; then dry_run "..."; else <real command>; fi` |
| Idempotency | `install.sh` and `harden.sh` are both safe to re-run |
| Template placeholders | `__VAR_NAME__` format, substituted with `sed -e "s\|__VAR__\|${VAR}\|g"`. Inputs validated by `validate_*()` before sed |
| Logging palette | `info` (blue) · `success` (green) · `warn` (yellow) · `error` (red+exit) · `step` (bold) · `dry_run` (yellow). Same set in install.sh / uninstall.sh / harden.sh |
| ShellCheck | Repo-wide CI (`shellcheck.yml`) runs on all `.sh` under `platforms/`; `configs/` excluded |
| Checksum registry | `declare -A FILE_CHECKSUMS` in `install.sh`. **Update the matching entry when any `configs/` or `modules/*.tpl` file changes** — recompute with `sha256sum <file>`. The repo-wide `scripts/pre-commit.sh` hook checks this automatically. |
| Cron placement | `/etc/cron.d/twdxos`, not root crontab. Cleanup line minute forced to `30` to offset from the WP update line |
| Log permissions | Created with `install -m 640 -o root -g adm` — not world-readable |
| Drop-in style | New OS-level config goes to `/etc/<thing>.d/99-twdxos-hardening.conf`, never mutates the upstream file |
| On-disk artifact naming | `twdxos` (rebranded from the original `twdxwpss` when this became a multi-platform project — no back-compat shim needed since no old-name installs existed to migrate) |

## Common Change Recipes

| Goal | Files to touch |
|---|---|
| Edit a config that ships to disk (e.g. tighten fail2ban) | (1) edit `configs/<file>` (2) `sha256sum configs/<file>` (3) update `FILE_CHECKSUMS["configs/<file>"]` in `install.sh` — the repo-wide pre-commit hook blocks the commit if you forget |
| Add a brand-new shipped config | (1) create `configs/<file>` (2) add `FILE_CHECKSUMS` entry (3) add a `fetch_verified` call in the matching `step` block in `install.sh` (4) add a removal line in `uninstall.sh` (5) update the Dependency Graph above |
| Tweak SSH or sysctl rule | edit the heredoc in `harden.sh` (SSH §1 / sysctl §2). No checksum — `harden.sh` embeds these inline, not via `fetch_verified` |
| Add a new env var | (1) default + interactive prompt block in `install.sh` (2) add a `validate_*` if non-trivial (3) document in `show_help` (4) document in `README.md`'s headless-configuration table |
| Change the WP update script | edit `modules/wp-auto-update.sh.tpl`, then bump its checksum (recipe row 1) |

## Quick Commands

```bash
# Lint locally (matches CI)
shellcheck install.sh uninstall.sh harden.sh declutter.sh

# Preview an install without writing anything
sudo bash install.sh --dry-run
sudo bash harden.sh --dry-run

# Recompute every shipped-file checksum (paste into FILE_CHECKSUMS)
for f in configs/50unattended-upgrades configs/20auto-upgrades configs/needrestart.conf \
         configs/auto-reboot.service configs/auto-reboot.timer.tpl configs/fail2ban-jail.local \
         configs/journald-twdxos.conf modules/wp-auto-update.sh.tpl; do
  printf '    ["%s"]="%s"\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"
done

# Lint like CI (also covers the enterprise scaffolding)
shellcheck --severity=style --format=gcc install.sh uninstall.sh harden.sh declutter.sh

# Smoke-test the JSON + exit-code contract without root
bash install.sh --json --non-interactive --dry-run ; echo "exit=$?"   # -> exit 3 (preflight: not root)
```

## What NOT to Read for Typical Tasks

| File | Skip when... |
|---|---|
| `README.md` | Any code task — it's user docs, not implementation |
| `configs/needrestart.conf` | Unless the question is specifically about needrestart policy |
