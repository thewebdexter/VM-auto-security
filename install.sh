#!/bin/bash
# =============================================================================
# wp-automaint
# https://github.com/thewebdexter/VM-auto-security
#
# Hands-off maintenance for headless WordPress servers.
# Handles OS updates, service restarts, kernel reboots, and WP updates
# so you can focus on building instead of maintaining.
#
# Usage:
#   sudo bash install.sh
#   sudo WP_PATH=/var/www/mysite WP_USER=nginx bash install.sh
#
# Tested: Ubuntu 24.04 LTS — aarch64 + x86_64
# License: MIT
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[info]${NC}  $*"; }
success() { echo -e "${GREEN}[ ok ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
error()   { echo -e "${RED}[fail]${NC}  $*"; exit 1; }
step()    { echo -e "\n${BOLD}▸ $*${NC}"; }

# ── Configuration ─────────────────────────────────────────────────────────────
# Override any of these by passing as environment variables before the script:
#   sudo WP_PATH=/srv/www/mysite WP_USER=nginx bash install.sh

WP_PATH="${WP_PATH:-/var/www/html}"          # path to WordPress root
WP_USER="${WP_USER:-www-data}"               # OS user that owns WP files
REBOOT_TIME="${REBOOT_TIME:-03:30:00}"       # nightly kernel-reboot check (UTC)
WP_CRON_HOUR="${WP_CRON_HOUR:-3}"            # hour to run WP updates (0-23)
WP_CRON_DOW="${WP_CRON_DOW:-0}"              # day of week (0=Sun … 6=Sat)
LOG_FILE="${LOG_FILE:-/var/log/wp-auto-update.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight"

[[ $EUID -ne 0 ]] && error "Please run as root: sudo bash install.sh"

command -v lsb_release &>/dev/null || apt-get install -y -q lsb-release
OS=$(lsb_release -si 2>/dev/null || echo "Unknown")
VER=$(lsb_release -sr 2>/dev/null || echo "0")

[[ "$OS" != "Ubuntu" ]] && warn "Tested on Ubuntu — proceeding anyway on $OS $VER"
info "System : $OS $VER ($(uname -m))"
info "WP path: $WP_PATH (owner: $WP_USER)"
info "Reboot : $REBOOT_TIME UTC | WP updates: day=$WP_CRON_DOW at ${WP_CRON_HOUR}:00 UTC"

# ── 1. unattended-upgrades ────────────────────────────────────────────────────
step "OS auto-updates (unattended-upgrades)"

apt-get install -y -q unattended-upgrades update-notifier-common powermgmt-base

cp -f "$SCRIPT_DIR/configs/50unattended-upgrades" /etc/apt/apt.conf.d/50unattended-upgrades
cp -f "$SCRIPT_DIR/configs/20auto-upgrades"        /etc/apt/apt.conf.d/20auto-upgrades

systemctl enable --now unattended-upgrades
success "unattended-upgrades active"

# ── 2. needrestart ────────────────────────────────────────────────────────────
step "Service auto-restart (needrestart)"

apt-get install -y -q needrestart
cp -f "$SCRIPT_DIR/configs/needrestart.conf" /etc/needrestart/needrestart.conf
success "needrestart configured (mode: automatic)"

# ── 3. Kernel-reboot timer ────────────────────────────────────────────────────
step "Auto-reboot timer"

cp -f "$SCRIPT_DIR/configs/auto-reboot.service" /etc/systemd/system/auto-reboot.service

sed "s|__REBOOT_TIME__|${REBOOT_TIME}|g" \
    "$SCRIPT_DIR/configs/auto-reboot.timer.tpl" \
    > /etc/systemd/system/auto-reboot.timer

systemctl daemon-reload
systemctl enable --now auto-reboot.timer
success "auto-reboot.timer scheduled nightly at $REBOOT_TIME UTC"

# ── 4. WP-CLI ─────────────────────────────────────────────────────────────────
step "WP-CLI"

if command -v wp &>/dev/null; then
    info "WP-CLI already installed at $(command -v wp) — skipping download"
else
    info "Downloading WP-CLI..."
    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp
    chmod +x /usr/local/bin/wp
    success "WP-CLI installed"
fi

wp --info --allow-root &>/dev/null \
    && success "WP-CLI OK" \
    || warn "WP-CLI installed but --info failed — verify PHP is available"

# ── 5. WordPress update script + cron ────────────────────────────────────────
step "WordPress auto-update cron"

sed -e "s|__WP_PATH__|${WP_PATH}|g" \
    -e "s|__WP_USER__|${WP_USER}|g" \
    -e "s|__LOG_FILE__|${LOG_FILE}|g" \
    "$SCRIPT_DIR/scripts/wp-auto-update.sh.tpl" \
    > /usr/local/bin/wp-auto-update.sh

chmod +x /usr/local/bin/wp-auto-update.sh
touch "$LOG_FILE"

# Idempotent: remove any existing entry, then re-add
CRON_LINE="0 ${WP_CRON_HOUR} * * ${WP_CRON_DOW} /usr/local/bin/wp-auto-update.sh"
( crontab -l 2>/dev/null | grep -v "wp-auto-update" ; echo "$CRON_LINE" ) | crontab -
success "Cron scheduled: day=$WP_CRON_DOW at ${WP_CRON_HOUR}:00 UTC"

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
echo -e "${GREEN}  wp-automaint installed successfully on $(hostname)${NC}"
echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
echo
printf "  %-28s %-14s %s\n" "Component" "Status" "Schedule"
echo  "  ──────────────────────────────────────────────────"
printf "  %-28s ${GREEN}%-14s${NC} %s\n" "OS security + bug fixes"  "✓ active" "Daily"
printf "  %-28s ${GREEN}%-14s${NC} %s\n" "Service restarts"          "✓ active" "On every apt run"
printf "  %-28s ${GREEN}%-14s${NC} %s\n" "Kernel reboot"             "✓ active" "Nightly $REBOOT_TIME UTC"
printf "  %-28s ${GREEN}%-14s${NC} %s\n" "WP core / plugins / themes" "✓ active" "DOW=$WP_CRON_DOW at ${WP_CRON_HOUR}:00 UTC"
echo
echo  "  Logs:"
echo  "    OS updates  →  /var/log/unattended-upgrades/unattended-upgrades.log"
echo  "    WP updates  →  $LOG_FILE"
echo
echo  "  Quick checks:"
echo  "    unattended-upgrade --dry-run"
echo  "    systemctl list-timers auto-reboot.timer"
echo  "    tail -f $LOG_FILE"
echo
