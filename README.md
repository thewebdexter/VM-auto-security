# VM-Auto-security

Hands-off maintenance for headless WordPress servers on Ubuntu 24.04. Set it up once and forget about it — security patches, bug fixes, service restarts, kernel reboots, and WordPress updates all happen automatically.

Built for lean cloud setups where you want the server to take care of itself.

---

## What it does

| Layer | Tool | When |
|---|---|---|
| OS security patches + bug fixes | `unattended-upgrades` | Daily |
| Restart services after library updates | `needrestart` | After every `apt` run |
| Reboot if a kernel update is pending | systemd timer | Nightly (default 03:30 UTC) |
| Update WP core, plugins, themes | WP-CLI + cron | Weekly (default Sunday 03:00 UTC) |

---

## Requirements

- Ubuntu 24.04 LTS (tested on both `x86_64` and `aarch64`)
- Root or sudo access
- WordPress already installed
- Outbound internet access (to fetch WP-CLI on first run)

---

## Install

```bash
git clone https://github.com/thewebdexter/VM-auto-security.git
cd wp-automaint
sudo bash install.sh
```

That's it. The script is idempotent — safe to re-run on an existing server.

---

## Configuration

Everything is controlled via environment variables. Pass them inline:

```bash
sudo WP_PATH=/var/www/mysite WP_USER=nginx bash install.sh
```

| Variable | Default | Description |
|---|---|---|
| `WP_PATH` | `/var/www/html` | Path to WordPress root |
| `WP_USER` | `www-data` | OS user that owns WP files |
| `REBOOT_TIME` | `03:30:00` | Nightly reboot check time (UTC) |
| `WP_CRON_HOUR` | `3` | Hour to run WP updates (0–23 UTC) |
| `WP_CRON_DOW` | `0` | Day of week for WP updates (0=Sun, 1=Mon …) |
| `LOG_FILE` | `/var/log/wp-auto-update.log` | WP update log path |

Full example with all options:

```bash
sudo \
  WP_PATH=/var/www/mysite \
  WP_USER=nginx \
  REBOOT_TIME=04:00:00 \
  WP_CRON_HOUR=4 \
  WP_CRON_DOW=1 \
  bash install.sh
```

---

## Verify the install

```bash
# OS updater running?
systemctl status unattended-upgrades

# Test a dry run
unattended-upgrade --dry-run

# Reboot timer scheduled?
systemctl list-timers auto-reboot.timer

# WP-CLI connected?
sudo -u www-data wp --path=/var/www/html core version

# WP update log (populated after first weekly run)
tail -f /var/log/wp-auto-update.log
```

---

## Logs

| What | Where |
|---|---|
| OS updates | `/var/log/unattended-upgrades/unattended-upgrades.log` |
| dpkg changes | `/var/log/unattended-upgrades/unattended-upgrades-dpkg.log` |
| WP updates | `/var/log/wp-auto-update.log` (configurable) |

---

## Notes

- **Reboots** only happen when a kernel update is actually pending (`/var/run/reboot-required`). Most nightly checks will do nothing.
- **WP plugin updates** can occasionally break a site. Check the log on Monday mornings if you're actively developing.
- **Cloudflared / tunnel daemons** reconnect automatically on reboot as long as they're enabled as systemd services.
- The installer does not touch your web server, database, or WordPress files directly — only system-level tooling is configured.

---

## Uninstall

```bash
# Remove cron job
crontab -l | grep -v "wp-auto-update" | crontab -

# Disable systemd timer
systemctl disable --now auto-reboot.timer
rm /etc/systemd/system/auto-reboot.{service,timer}
systemctl daemon-reload

# Disable unattended-upgrades (optional — it's a standard Ubuntu package)
systemctl disable --now unattended-upgrades

# Remove WP-CLI
rm /usr/local/bin/wp /usr/local/bin/wp-auto-update.sh
```

---

## License

MIT
