# TWDxOSOptimisation — Linux (Debian/Ubuntu)

Hands-off maintenance for headless servers on Ubuntu 24.04 (and Debian-family distros generally). Set it up once and forget about it — security patches, bug fixes, service restarts, kernel reboots, system cleanup, log rotation, intrusion prevention, and (optionally) WordPress updates all happen automatically.

This is the original project (formerly `TWDxWordPressServerSecurity`), now living as one self-contained folder inside a larger multi-platform project. It has no dependency on any other platform folder in this repo.

**Developed by [TheWebDexter.com](https://thewebdexter.com)**

---

## What it does

| Layer | Tool | When |
|---|---|---|
| OS **security** updates (security pocket only by default) | `unattended-upgrades` | Daily |
| Intrusion Prevention (SSH brute-force + repeat-offender ban) | `fail2ban` (tuned jail, `ignoreip` = loopback only) | Always Active |
| Report services running outdated code (list-only by default) | `needrestart` | After every `apt` run |
| Reboot if a kernel update is pending (5-min grace + `wall`) | systemd timer | Nightly (default 03:30 UTC) |
| Time synchronisation is enabled & active | `chrony` / `systemd-timesyncd` | Always |
| journald: persistent, size-capped, 1-month retention | `journald.conf.d` drop-in | Always |
| System Cleanup (apt caches & journal) | bash + cron | Configurable (Default: Weekly) |
| Log Rotation (compress & clean old logs) | `logrotate` | Weekly |
| Update WP core, plugins, themes + DB optimize | WP-CLI + cron (`flock`) | **Only when `WP_PATH` is set** |

> **v2.0.0 changed several defaults** (security-only updates, `needrestart`
> list-only, fail2ban loopback-only, WP opt-in). See the repo
> [`CHANGELOG.md`](../../CHANGELOG.md) before re-running on an existing host.

---

## Requirements

- Ubuntu 24.04 LTS (tested on both `x86_64` and `aarch64`)
- Root or sudo access
- Outbound internet access (to fetch configs on first run; WP-CLI too, if the optional module is used)

---

## Quick Install (Recommended)

```bash
# Pin a release tag in production (see the repo's Releases page):
curl -fsSL https://raw.githubusercontent.com/TheWebDexterTech/TWDxOSOptimisation/v2.0.0/platforms/linux-debian/install.sh | sudo bash
```

The script is entirely **idempotent** — safe to re-run.

> **Security note:** every fetched file is verified against a SHA256 digest
> baked into `install.sh` before it is written. With `--require-signatures`
> a minisign signature is also required. WP-CLI is verified against its
> SHA512 (pin an exact digest with `WP_CLI_PINNED_SHA512`). Any mismatch
> aborts with exit code 5.

### Enterprise flags (all scripts)

| Flag / env | Effect |
|---|---|
| `--dry-run` / `DRY_RUN=true` | Preview only |
| `--json` / `JSON_OUTPUT=true` | JSON result on stdout, logs on stderr |
| `--offline` / `OFFLINE=true` | No fetches; run from a checkout (`BUNDLE_DIR=…`) |
| `--non-interactive` / `NON_INTERACTIVE=true` | Never prompt; fail closed |
| `--require-signatures` / `REQUIRE_SIGNATURES=true` | minisign check mandatory |
| `--strict` | `--non-interactive` + `--require-signatures` |
| `--ref <tag\|sha>` / `TWDX_REF` | Fetch configs from this git ref |
| `ENABLE_UNATTENDED_UPGRADES` / `ENABLE_FAIL2BAN` / `ENABLE_NEEDRESTART` / `ENABLE_AUTO_REBOOT` / `ENABLE_TIMESYNC` / `ENABLE_JOURNALD_TUNING` | `true` — turn a component off if your fleet manages it centrally |

Exit codes: `0` ok · `2` usage · `3` preflight · `4` partial · `5` integrity.

Air-gapped:

```bash
git clone … && cd TWDxOSOptimisation/platforms/linux-debian
sudo BUNDLE_DIR="$PWD" bash install.sh --offline --non-interactive --json
```

## Manual Install (Clone Repository)

```bash
git clone https://github.com/TheWebDexterTech/TWDxOSOptimisation.git
cd TWDxOSOptimisation/platforms/linux-debian
sudo bash install.sh
```

## Dry-Run Mode

```bash
sudo bash install.sh --dry-run
# or
sudo DRY_RUN=true bash install.sh
```

---

## Server Hardening (Optional)

```bash
sudo bash harden.sh [--dry-run]
```

| Layer | What it does |
|---|---|
| SSH daemon | Writes a drop-in at `/etc/ssh/sshd_config.d/99-twdxos-hardening.conf` so the main `sshd_config` is left untouched. CIS-aligned: disables root login, passwords, agent/TCP/X11 forwarding, sets `MaxAuthTries 3`, `LoginGraceTime 30`, `ClientAliveInterval 300`, and pins Mozilla "modern" KEX/Ciphers/MACs/HostKeyAlgorithms. Validates with `sshd -t` before reload. |
| Kernel & network stack | Writes `/etc/sysctl.d/99-twdxos-hardening.conf`: TCP SYN cookies, rp_filter, no redirects / source routing (v4 **and** v6), martian logging, `kptr_restrict=2`, `dmesg_restrict=1`, `yama.ptrace_scope=2`, `kexec_load_disabled=1`, `unprivileged_bpf_disabled=1`, BPF JIT hardening, and the full `fs.protected_*` family. |
| UFW firewall | Installs and enables UFW (IPv6 explicit, low logging) with `deny incoming` / `allow outgoing` defaults, and opens your SSH port, HTTP (80), and HTTPS (443). SSH `allow` rule is added **before** the firewall is enabled. |
| `/dev/shm` + `/tmp` mount options | `HARDEN_SHM` (default **on**): `/dev/shm` → `nodev,nosuid,noexec` via fstab + live remount. `HARDEN_TMP` (default **off**, opt-in): `/tmp` → `nodev,nosuid` (`HARDEN_TMP_NOEXEC=true` adds `noexec` — can break apt hooks/installers). |
| AppArmor | Reported only — warns if installed-but-disabled. |
| sysctl additions (v2.0.0) | `arp_ignore/announce`, `ip_forward=0`, `accept_ra=0` (v6), `perf_event_paranoid=3`, `randomize_va_space=2`. |

**Headless example:**

```bash
sudo SSH_PORT=2222 OPEN_HTTP=false bash harden.sh --non-interactive --json
```

| Variable | Default | Description |
|---|---|---|
| `SSH_PORT` | `22` | Port UFW keeps open for SSH (also written as `Port` in the SSH drop-in when ≠ 22) |
| `ENABLE_UFW` | `true` | Install and enable UFW |
| `OPEN_HTTP` / `OPEN_HTTPS` | `true` | Allow ports 80 / 443 |
| `HARDEN_SSH` / `HARDEN_SYSCTL` | `true` | Toggle those sections |
| `HARDEN_SHM` | `true` | Harden `/dev/shm` mount options |
| `HARDEN_TMP` / `HARDEN_TMP_NOEXEC` | `false` | Opt-in `/tmp` mount hardening |
| `ALLOW_PASSWORD_LOCKOUT` | `false` | Proceed even with no SSH key present |

> **Lockout guard:** `harden.sh` checks for a usable key-based auth path
> (any user's `authorized_keys`, root's, `authorized_keys.d/`, or an
> `AuthorizedKeysCommand`) before disabling password auth. With no key and
> **no TTY** it now **aborts** (exit 3) unless `ALLOW_PASSWORD_LOCKOUT=true`.

### Raising the Drawbridge (Cloudflare Tunnel)

For maximum security, route SSH through a Cloudflare Zero Trust tunnel so the server has zero open inbound ports. Once the tunnel is confirmed working, remove the SSH rule:

```bash
sudo ufw delete allow 22/tcp && sudo ufw reload
```

Also delete the SSH ingress rule from your cloud provider's VCN / Security Group (e.g. Oracle Cloud Dashboard).

### Ubuntu Pro (Extended Security Maintenance)

```bash
sudo pro attach YOUR_TOKEN_HERE
```

Optional — `unattended-upgrades` already covers the base Ubuntu packages without it.

---

## Headless Configuration (install.sh)

```bash
curl -fsSL https://raw.githubusercontent.com/TheWebDexterTech/TWDxOSOptimisation/main/platforms/linux-debian/install.sh | \
  sudo WP_PATH=/var/www/mysite \
  WP_USER=nginx \
  ENABLE_CLEANUP=true \
  CRON_SCHEDULE="0 4 * * 1" \
  ADMIN_EMAIL=ops@yourcompany.com \
  bash
```

| Variable | Default | Description |
| --- | --- | --- |
| `WP_PATH` | *(empty)* | **Unset = WordPress module disabled.** Set it to a WP root to install WP-CLI + the weekly WP update cron. |
| `WP_USER` | `www-data` | OS user that owns WP files |
| `WP_CLI_PINNED_SHA512` | *(empty)* | Enforce an exact WP-CLI digest instead of the upstream TOFU `.sha512` |
| `ENABLE_CLEANUP` | prompt / `true` | `apt autoremove/autoclean` + journal trim, weekly |
| `CRON_SCHEDULE` | `0 3 * * 0` | Cron string for the WP / cleanup jobs |
| `REBOOT_TIME` | `03:30:00` | Nightly reboot-check time (HH:MM:SS) |
| `LOG_FILE` | `/var/log/wp-auto-update.log` | WP update log path |
| `ADMIN_EMAIL` | *(empty)* | Validated e-mail. Sets cron `MAILTO` **and** writes `/etc/apt/apt.conf.d/52unattended-upgrades-twdxos` so `unattended-upgrades` failures are mailed too (needs an MTA / `bsd-mailx`). |

*(If `ENABLE_CLEANUP` is true, the cleanup job runs 30 minutes after the WP job to avoid a CPU spike.)*

---

## Declutter script

```bash
sudo bash declutter.sh                       # report only
sudo bash declutter.sh --apply               # apt full-upgrade, autoremove, cache/log/tmp cleanup
sudo bash declutter.sh --apply --aggressive  # + interactive review of inactive services / unused packages
sudo bash declutter.sh --cron                # non-interactive, for scheduled runs
sudo bash declutter.sh --json                # machine-readable summary on stdout
```

Logs to `/var/log/linux-declutter/` (dir `0750`, files `0640`). Temp cleanup
now prefers `systemd-tmpfiles --clean` and never touches sockets,
`systemd-private-*`, `.X11-unix`, etc.

## Verify the install

```bash
systemctl status unattended-upgrades
systemctl status fail2ban
unattended-upgrade --dry-run
systemctl list-timers auto-reboot.timer
sudo -u www-data wp --path=/var/www/html core version   # if the WP-CLI module is enabled
cat /etc/cron.d/twdxos
```

## Logs

| What | Where |
| --- | --- |
| OS updates | `/var/log/unattended-upgrades/unattended-upgrades.log` |
| Intrusion blocks | `/var/log/fail2ban.log` (jail status: `sudo fail2ban-client status sshd`) |
| WP updates | `/var/log/wp-auto-update.log` |
| System Cleanup | `/var/log/vm-system-cleanup.log` |

Log files are created with mode `640` (root:adm) — not world-readable.

## Optional WordPress module

`modules/wp-auto-update.sh.tpl` is not the centerpiece of this platform. It's installed only via the WP-CLI section of `install.sh`, which no-ops safely (just a warning) if WordPress isn't found at `WP_PATH`.

## Notes

* **Reboots** only happen when a kernel update is actually pending (`/var/run/reboot-required`).
* **Reboots with active users** are disabled by default — see `/etc/apt/apt.conf.d/50unattended-upgrades` to adjust.
* **Cron jobs** are written to `/etc/cron.d/twdxos` rather than the root crontab.

## Uninstall

```bash
sudo bash uninstall.sh
```

## License

MIT
