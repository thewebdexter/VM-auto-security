#!/bin/bash
# =============================================================================
# TWDxOSOptimisation — Linux (Debian/Ubuntu) Uninstaller
# https://github.com/TheWebDexterTech/TWDxOSOptimisation
#
# Reverses install.sh and (optionally) harden.sh.
#
# Flags:  --non-interactive  --assume-yes  --purge  --json  --dry-run
#   --purge            also remove things kept by default (WP-CLI, disable
#                      fail2ban/unattended-upgrades, revert firewall/sysctl)
# Exit codes:  0 ok · 2 usage · 3 preflight
# =============================================================================

set -euo pipefail

TWDX_VERSION="2.0.0"
EX_OK=0; EX_ERR=1; EX_USAGE=2; EX_PREFLIGHT=3

DRY_RUN="${DRY_RUN:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
ASSUME_YES="${ASSUME_YES:-false}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"
PURGE="${PURGE:-false}"

if [[ -t 1 && "$JSON_OUTPUT" != "true" ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; CYAN=""; NC=""
fi
_out() { if [[ "$JSON_OUTPUT" == "true" ]]; then printf '%b\n' "$*" >&2; else printf '%b\n' "$*"; fi; }
info()    { _out "${BLUE}[info]${NC}  $*"; }
success() { _out "${GREEN}[ ok ]${NC}  $*"; }
warn()    { _out "${YELLOW}[warn]${NC}  $*"; }
die()     { _out "${RED}[fail]${NC}  $1"; exit "${2:-$EX_ERR}"; }

REMOVED=()
note_removed() { REMOVED+=("$1"); success "$1"; }

confirm() {   # confirm <prompt>  (used only for --purge extras)
    [[ "$ASSUME_YES" == "true" ]] && return 0
    if [[ "$NON_INTERACTIVE" == "true" || ! -c /dev/tty ]]; then return 1; fi
    local ans; read -r -p "$1 [y/N]: " ans < /dev/tty || return 1
    [[ "$ans" =~ ^[Yy]$ ]]
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) sed -n '2,14p' "$0"; exit 0 ;;
        --dry-run|--check) DRY_RUN="true" ;;
        --non-interactive) NON_INTERACTIVE="true" ;;
        --assume-yes|--yes|-y) ASSUME_YES="true" ;;
        --purge) PURGE="true" ;;
        --json) JSON_OUTPUT="true" ;;
        *) die "Unknown argument: $1" "$EX_USAGE" ;;
    esac
    shift
done
[[ "$JSON_OUTPUT" == "true" || ! -t 1 ]] && { RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; CYAN=""; NC=""; }

[[ $EUID -ne 0 ]] && die "Run as root (sudo)." "$EX_PREFLIGHT"

[[ "$JSON_OUTPUT" == "true" ]] || {
    printf '%b\n' "${CYAN}${BOLD}"
    echo "  ================================================================="
    echo "     TWDxOSOptimisation — Linux (Debian/Ubuntu) Uninstaller  v${TWDX_VERSION}"
    echo "  ================================================================="
    printf '%b\n' "${NC}"
}

if [[ "$NON_INTERACTIVE" != "true" && "$ASSUME_YES" != "true" && -c /dev/tty ]]; then
    warn "This removes all TWDxOSOptimisation components."
    read -r -p "  Continue? [y/N]: " c < /dev/tty || c=""
    [[ "$c" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
fi

run() { if [[ "$DRY_RUN" == "true" ]]; then _out "[dry-run] $*"; else "$@"; fi; }

# ── Always-removed artifacts ───────────────────────────────────────────────
run rm -f /etc/cron.d/twdxos && note_removed "/etc/cron.d/twdxos"

run systemctl disable --now auto-reboot.timer 2>/dev/null || true
run rm -f /etc/systemd/system/auto-reboot.service /etc/systemd/system/auto-reboot.timer
run systemctl daemon-reload || true
note_removed "auto-reboot.timer + service"

for f in /usr/local/bin/wp-auto-update.sh /usr/local/bin/vm-system-cleanup.sh \
         /var/lock/wp-auto-update.lock; do
    [[ -e "$f" ]] && { run rm -f "$f"; note_removed "$f"; }
done

run rm -f /etc/logrotate.d/twdxos /etc/logrotate.d/vm-auto-security
note_removed "logrotate config"

run rm -f /etc/apt/apt.conf.d/52unattended-upgrades-twdxos
note_removed "unattended-upgrades mail drop-in"

if [[ -f /etc/systemd/journald.conf.d/99-twdxos.conf ]]; then
    run rm -f /etc/systemd/journald.conf.d/99-twdxos.conf
    run systemctl restart systemd-journald 2>/dev/null || true
    note_removed "journald tuning drop-in"
fi

if [[ -f /etc/sysctl.d/99-twdxos-hardening.conf ]]; then
    run rm -f /etc/sysctl.d/99-twdxos-hardening.conf
    run sysctl --system >/dev/null 2>&1 || true
    note_removed "sysctl hardening drop-in"
fi

if [[ -f /etc/ssh/sshd_config.d/99-twdxos-hardening.conf ]]; then
    run rm -f /etc/ssh/sshd_config.d/99-twdxos-hardening.conf
    run systemctl reload ssh 2>/dev/null || run systemctl reload sshd 2>/dev/null || true
    note_removed "SSH hardening drop-in"
fi

if grep -q ' # twdxos-hardening$' /etc/fstab 2>/dev/null; then
    run sed -i '\| # twdxos-hardening$|d' /etc/fstab
    note_removed "fstab mount-hardening lines (reboot to fully revert /tmp,/dev/shm)"
fi

# fail2ban jail we shipped
if [[ -f /etc/fail2ban/jail.local ]]; then
    if [[ "$PURGE" == "true" ]] || confirm "Remove /etc/fail2ban/jail.local?"; then
        run rm -f /etc/fail2ban/jail.local
        run systemctl restart fail2ban 2>/dev/null || true
        note_removed "/etc/fail2ban/jail.local"
    fi
fi

# ── Optional (only with --purge or a yes) ────────────────────────────────
if [[ "$PURGE" == "true" ]] || confirm "Remove WP-CLI (/usr/local/bin/wp)?"; then
    [[ -e /usr/local/bin/wp ]] && { run rm -f /usr/local/bin/wp; note_removed "WP-CLI"; }
fi
if [[ "$PURGE" == "true" ]] || confirm "Disable unattended-upgrades and fail2ban services?"; then
    run systemctl disable --now unattended-upgrades fail2ban 2>/dev/null || true
    note_removed "disabled unattended-upgrades + fail2ban"
fi
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    if [[ "$PURGE" == "true" ]] || confirm "Disable UFW firewall?"; then
        run ufw --force disable >/dev/null 2>&1 || true
        note_removed "UFW disabled"
    fi
fi
if [[ -f /etc/ssh/sshd_config.bak ]]; then
    if confirm "Legacy SSH backup found — restore /etc/ssh/sshd_config from it?"; then
        run cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
        run systemctl restart ssh 2>/dev/null || true
        note_removed "restored legacy sshd_config"
    fi
fi

# NOTE: time synchronisation (systemd-timesyncd/chrony) is an OS baseline and
# is deliberately left enabled.

if [[ "$JSON_OUTPUT" == "true" ]]; then
    joined=""; first=1
    for r in "${REMOVED[@]:-}"; do
        e=${r//\\/\\\\}; e=${e//\"/\\\"}
        if [[ $first -eq 1 ]]; then joined="\"$e\""; first=0; else joined="$joined,\"$e\""; fi
    done
    printf '{"tool":"twdxos","platform":"linux-debian","script":"uninstall","version":"%s","dry_run":%s,"purge":%s,"removed":[%s],"timestamp":"%s"}\n' \
        "$TWDX_VERSION" "$DRY_RUN" "$PURGE" "$joined" "$(date -Iseconds)"
else
    _out "\n${GREEN}${BOLD}  TWDxOSOptimisation removed.${NC}"
    _out "  Logs kept under /var/log/ — remove manually if unwanted."
fi
exit "$EX_OK"
