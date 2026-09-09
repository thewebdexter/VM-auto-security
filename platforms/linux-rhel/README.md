# TWDxOSOptimisation — Linux (RHEL/Fedora/CentOS)

Hands-off maintenance for headless servers on the RHEL family: RHEL, CentOS Stream, Rocky Linux, AlmaLinux, and Fedora. Set it up once and forget about it — security patches, service restarts, kernel reboots, system cleanup, log rotation, intrusion prevention, and (optionally) WordPress updates all happen automatically.

This folder is self-contained — it has no dependency on any other platform folder in this repo.

**Developed by [TheWebDexter.com](https://thewebdexter.com)**

---

## What it does

| Layer | Tool | When |
|---|---|---|
| OS security patches + bug fixes | `dnf-automatic` | Daily (via `dnf-automatic-install.timer`) |
| Intrusion Prevention (SSH brute-force + repeat-offender ban) | `fail2ban` (tuned jail, EPEL) | Always Active |
| Restart services after library updates | `needrestart` (EPEL) | After every `dnf` run |
| Reboot if a pending update requires it | systemd timer + `dnf needs-restarting -r` | Nightly (default 03:30 UTC) |
| System Cleanup (dnf cache & logs) | bash + cron | Configurable (Default: Weekly) |
| Log Rotation (compress & clean old logs) | `logrotate` | Weekly |
| Update WP core, plugins, themes, and DB Optimize (optional module) | WP-CLI + cron (with `flock` lock) | Configurable (Default: Weekly) |

## Requirements

- RHEL 9, CentOS Stream 9, Rocky Linux 9, AlmaLinux 9, or Fedora 40+ (x86_64 / aarch64)
- Root or sudo access
- Outbound internet access (to fetch configs on first run, and EPEL/dnf-automatic packages)

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/TheWebDexterTech/TWDxOSOptimisation/v2.0.0/platforms/linux-rhel/install.sh | sudo bash
```

Idempotent — safe to re-run. Every fetched file is verified against a SHA256 digest in `install.sh` (and, with `--require-signatures`, a minisign signature). Mismatch aborts with exit 5.

### Enterprise flags (all scripts)

`--json` · `--offline` (with `BUNDLE_DIR`) · `--non-interactive` · `--require-signatures` · `--strict` · `--ref <tag|sha>` · env toggles `ENABLE_DNF_AUTOMATIC` / `ENABLE_FAIL2BAN` / `ENABLE_NEEDRESTART` / `ENABLE_AUTO_REBOOT` / `ENABLE_TIMESYNC` / `ENABLE_JOURNALD_TUNING`. Exit codes: `0` ok · `2` usage · `3` preflight · `4` partial · `5` integrity.

> **v2.0.0 changed defaults** — `dnf-automatic` is now security-only, `needrestart` is list-only, `fail2ban` `ignoreip` is loopback-only, and the WP module installs **only when `WP_PATH` is set**. See [`CHANGELOG.md`](../../CHANGELOG.md).

## Manual Install (clone repository)

```bash
git clone https://github.com/TheWebDexterTech/TWDxOSOptimisation.git
cd TWDxOSOptimisation/platforms/linux-rhel
sudo bash install.sh
```

## Dry-Run Mode

```bash
sudo bash install.sh --dry-run
```

## Server Hardening (Optional)

```bash
sudo bash harden.sh [--dry-run]
```

| Layer | What it does |
|---|---|
| SSH daemon | Drop-in at `/etc/ssh/sshd_config.d/99-twdxos-hardening.conf`. CIS-aligned: disables root login, passwords, agent/TCP/X11 forwarding, sets `MaxAuthTries 3`, pins Mozilla "modern" KEX/Ciphers/MACs. Validates with `sshd -t` before reload. |
| Kernel & network stack | `/etc/sysctl.d/99-twdxos-hardening.conf`: TCP SYN cookies, rp_filter, no redirects/source routing (v4 + v6), martian logging, `kptr_restrict`, `dmesg_restrict`, `yama.ptrace_scope`, `fs.protected_*` family. |
| firewalld | Installs and enables firewalld, opens SSH port + HTTP/HTTPS services. |

**Headless example:**

```bash
sudo SSH_PORT=22 OPEN_HTTP=true OPEN_HTTPS=true bash harden.sh
```

| Variable | Default | Description |
|---|---|---|
| `SSH_PORT` | `22` | Port firewalld will keep open for SSH |
| `ENABLE_FIREWALLD` | `true` | Install and enable firewalld |
| `OPEN_HTTP` | `true` | Allow port 80 (required for Let's Encrypt / Cloudflare) |
| `OPEN_HTTPS` | `true` | Allow port 443 |
| `DRY_RUN` | `false` | Preview all changes without applying |

> **SELinux:** this script and `install.sh` never change SELinux mode or policy. If a hardening or WP-CLI step is blocked under `Enforcing`, use `audit2why < /var/log/audit/audit.log` and a targeted policy module (or `restorecon -Rv <path>`) rather than switching to Permissive.

## Headless Configuration (install.sh)

```bash
curl -fsSL https://raw.githubusercontent.com/TheWebDexterTech/TWDxOSOptimisation/v2.0.0/platforms/linux-rhel/install.sh | \
  sudo WP_PATH=/var/www/mysite \
  WP_USER=apache \
  ENABLE_CLEANUP=true \
  CRON_SCHEDULE="0 4 * * 1" \
  ADMIN_EMAIL=ops@yourcompany.com \
  bash
```

| Variable | Default | Description |
| --- | --- | --- |
| `WP_PATH` | `/var/www/html` | Absolute path to WordPress root (optional module) |
| `WP_USER` | `apache` | OS user that owns WP files |
| `ENABLE_CLEANUP` | `true` | Automates `dnf autoremove`/`clean all` and journal log trimming |
| `CRON_SCHEDULE` | `0 3 * * 0` | Standard cron string for WP updates (Default: Sun 03:00) |
| `REBOOT_TIME` | `03:30:00` | Nightly reboot check time (UTC, format HH:MM:SS) |
| `LOG_FILE` | `/var/log/wp-auto-update.log` | WP update log path |
| `ADMIN_EMAIL` | *(empty)* | Email address for cron failure alerts (sets `MAILTO`) |
| `DRY_RUN` | `false` | Preview without applying |

## Declutter script

```bash
sudo bash declutter.sh                       # report only
sudo bash declutter.sh --apply               # dnf upgrade, autoremove, cache/log/tmp cleanup
sudo bash declutter.sh --apply --aggressive  # + interactive review of inactive services / unused packages
sudo bash declutter.sh --cron                # non-interactive, for scheduled runs
```

Logs to `/var/log/rhel-declutter/`.

## Verify the install

```bash
systemctl status dnf-automatic-install.timer
systemctl status fail2ban
systemctl list-timers auto-reboot.timer
firewall-cmd --list-all
sudo -u apache wp --path=/var/www/html core version   # if the WP-CLI module is enabled
cat /etc/cron.d/twdxos
```

## Optional WordPress module

`modules/wp-auto-update.sh.tpl` is the same idempotent WP-CLI maintenance script used on the Debian platform, adapted for this platform's default `WP_USER=apache`. It is not the centerpiece of this platform — skip it entirely if you're not running WordPress by not relying on the WP-CLI section of `install.sh` (it silently no-ops if WordPress isn't found at `WP_PATH`, only warning that the cron job may fail).

## Uninstall

```bash
sudo bash uninstall.sh
```

## License

MIT
