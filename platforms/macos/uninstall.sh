#!/bin/bash
# =============================================================================
# TWDxOSOptimisation — macOS Uninstaller
# https://github.com/TheWebDexterTech/TWDxOSOptimisation
#
# Flags:  --non-interactive  --assume-yes  --purge  --json  --dry-run
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
confirm() {
    [[ "$ASSUME_YES" == "true" ]] && return 0
    if [[ "$NON_INTERACTIVE" == "true" || ! -c /dev/tty ]]; then return 1; fi
    local ans; read -r -p "$1 [y/N]: " ans < /dev/tty || return 1
    [[ "$ans" =~ ^[Yy]$ ]]
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) sed -n '2,9p' "$0"; exit 0 ;;
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

[[ "$(uname -s)" != "Darwin" ]] && die "This script targets macOS only." "$EX_PREFLIGHT"
[[ $EUID -ne 0 ]] && die "Run via: sudo bash uninstall.sh" "$EX_PREFLIGHT"

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER=$(stat -f%Su /dev/console 2>/dev/null || echo "")
fi
[[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]] && die "Could not determine a non-root console user." "$EX_PREFLIGHT"
TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null) || die "User '$TARGET_USER' not found." "$EX_PREFLIGHT"
TARGET_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')

[[ "$JSON_OUTPUT" == "true" ]] || {
    printf '%b\n' "${CYAN}${BOLD}"
    echo "  ================================================================="
    echo "     TWDxOSOptimisation — macOS Uninstaller  v${TWDX_VERSION}       "
    echo "  ================================================================="
    printf '%b\n' "${NC}"
}
if [[ "$NON_INTERACTIVE" != "true" && "$ASSUME_YES" != "true" && -c /dev/tty ]]; then
    warn "This removes all TWDxOSOptimisation components for $TARGET_USER."
    read -r -p "  Continue? [y/N]: " c < /dev/tty || c=""
    [[ "$c" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
fi

run() { if [[ "$DRY_RUN" == "true" ]]; then _out "[dry-run] $*"; else "$@"; fi; }

DECLUTTER_PLIST="$TARGET_HOME/Library/LaunchAgents/com.twdxos.declutter.plist"
if [[ -f "$DECLUTTER_PLIST" ]]; then
    run launchctl bootout "gui/$TARGET_UID" "$DECLUTTER_PLIST" 2>/dev/null || true
    run rm -f "$DECLUTTER_PLIST"
    note_removed "declutter LaunchAgent"
fi

[[ -f /usr/local/bin/twdxos-declutter.sh ]] && { run rm -f /usr/local/bin/twdxos-declutter.sh; note_removed "/usr/local/bin/twdxos-declutter.sh"; }

if [[ -f /usr/local/bin/wp-auto-update.sh ]]; then
    if [[ "$PURGE" == "true" ]] || confirm "Remove the optional WP-CLI module (/usr/local/bin/wp-auto-update.sh)?"; then
        run rm -f /usr/local/bin/wp-auto-update.sh
        run rm -f "${TMPDIR:-/tmp}/twdxos-wp-auto-update.${TARGET_UID}.lock" /tmp/wp-auto-update.lock
        note_removed "WP-CLI module"
    fi
fi

if [[ -f /etc/ssh/sshd_config.d/99-twdxos-hardening.conf ]]; then
    run rm -f /etc/ssh/sshd_config.d/99-twdxos-hardening.conf
    run bash -c 'launchctl print system/com.openssh.sshd >/dev/null 2>&1 && launchctl kickstart -k system/com.openssh.sshd' 2>/dev/null || true
    note_removed "SSH hardening drop-in"
fi

if [[ -x /usr/libexec/ApplicationFirewall/socketfilterfw ]]; then
    if [[ "$PURGE" == "true" ]] || confirm "Disable the Application Firewall?"; then
        run /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off >/dev/null
        note_removed "Application Firewall disabled"
    fi
fi

if [[ "$JSON_OUTPUT" == "true" ]]; then
    joined=""; first=1
    for r in "${REMOVED[@]:-}"; do
        e=${r//\\/\\\\}; e=${e//\"/\\\"}
        if [[ $first -eq 1 ]]; then joined="\"$e\""; first=0; else joined="$joined,\"$e\""; fi
    done
    printf '{"tool":"twdxos","platform":"macos","script":"uninstall","version":"%s","dry_run":%s,"purge":%s,"removed":[%s],"timestamp":"%s"}\n' \
        "$TWDX_VERSION" "$DRY_RUN" "$PURGE" "$joined" "$(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
else
    _out "\n${GREEN}${BOLD}  TWDxOSOptimisation removed.${NC}"
    _out "  Logs kept under \$HOME/Library/Logs/macos-declutter/."
fi
exit "$EX_OK"
