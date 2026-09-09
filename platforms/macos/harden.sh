#!/bin/bash
# =============================================================================
# TWDxOSOptimisation — macOS Hardening
# https://github.com/TheWebDexterTech/TWDxOSOptimisation
#
# Enables the Application Firewall (+ stealth mode), hardens sshd_config via
# a drop-in *only if* the OS build supports the Include mechanism, and
# REPORTS (never silently changes) FileVault, Gatekeeper, SIP and the
# screen-lock delay.
#
# Enterprise flags:  --json  --non-interactive  --strict  --dry-run
# Exit codes:  0 ok · 2 usage · 3 preflight · 4 partial
#
# Tested: macOS 26 Tahoe, Sequoia, Sonoma — Apple Silicon + Intel
# License: MIT
# =============================================================================

set -euo pipefail

TWDX_VERSION="2.0.0"
TWDX_PLATFORM="macos"
TWDX_SCRIPT="harden"

EX_OK=0; EX_ERR=1; EX_USAGE=2; EX_PREFLIGHT=3; EX_PARTIAL=4

DRY_RUN="${DRY_RUN:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"

ENABLE_APP_FIREWALL="${ENABLE_APP_FIREWALL:-true}"
ENABLE_SSH_HARDEN="${ENABLE_SSH_HARDEN:-true}"

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
step()    { _out "\n${BOLD}▸ $*${NC}"; }
dry_run() { _out "${YELLOW}[dry-run]${NC}  Would: $*"; }

declare -a JSON_STEPS=()
STEP_FAILURES=0
FINAL_EXIT=0
_JSON_EMITTED=""

json_escape() { local s=${1-}; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}; printf '%s' "$s"; }
mark_step() {
    JSON_STEPS+=("$(printf '{"name":"%s","status":"%s","detail":"%s"}' "$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "${3:-}")")")
    if [[ "$2" == "failed" ]]; then STEP_FAILURES=$((STEP_FAILURES + 1)); fi
    case "$2" in
        failed)  warn "step '$1' failed${3:+: $3}" ;;
        skipped) info "step '$1' skipped${3:+: $3}" ;;
    esac
}
emit_json() {
    [[ "$JSON_OUTPUT" == "true" ]] || return 0
    [[ -n "$_JSON_EMITTED" ]] && return 0
    _JSON_EMITTED=1
    local joined="" first=1 s
    for s in "${JSON_STEPS[@]:-}"; do
        [[ -z "$s" ]] && continue
        if [[ $first -eq 1 ]]; then joined="$s"; first=0; else joined="$joined,$s"; fi
    done
    printf '{"tool":"twdxos","platform":"%s","script":"%s","version":"%s","result":"%s","dry_run":%s,"failures":%d,"exit_code":%d,"host":"%s","timestamp":"%s","steps":[%s]}\n' \
        "$TWDX_PLATFORM" "$TWDX_SCRIPT" "$TWDX_VERSION" "$1" "$DRY_RUN" "$STEP_FAILURES" "$FINAL_EXIT" \
        "$(json_escape "$(hostname 2>/dev/null || echo host)")" "$(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" "$joined"
}
# shellcheck disable=SC2317,SC2329  # reached only via 'trap ... EXIT'
_on_exit() {
    local rc=$?
    if [[ "$JSON_OUTPUT" == "true" && -z "$_JSON_EMITTED" ]]; then
        FINAL_EXIT=$rc
        case "$rc" in
            0)             emit_json "ok" ;;
            "$EX_PARTIAL") emit_json "partial" ;;
            *)             emit_json "error" ;;
        esac
    fi
}
trap _on_exit EXIT

die() {
    local code="${2:-$EX_ERR}"
    _out "${RED}[fail]${NC}  $1"
    FINAL_EXIT="$code"
    emit_json "error"
    exit "$code"
}
validate_bool() { [[ "$1" == "true" || "$1" == "false" ]] || die "$2 must be true/false (got '$1')" "$EX_USAGE"; }

show_help() {
    cat <<'EOF'
TWDxOSOptimisation — macOS Hardening

Usage: sudo bash harden.sh [--dry-run|--json|--non-interactive|--strict|--help]

Environment:
  ENABLE_APP_FIREWALL [true]   ENABLE_SSH_HARDEN [true]

FileVault, Gatekeeper and SIP are REPORTED, never changed by this script.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)          show_help; exit 0 ;;
        --dry-run|--check)   DRY_RUN="true" ;;
        --json)             JSON_OUTPUT="true" ;;
        --non-interactive)  NON_INTERACTIVE="true" ;;
        --strict)           NON_INTERACTIVE="true" ;;
        *)                  die "Unknown argument: $1 (use --help)" "$EX_USAGE" ;;
    esac
    shift
done
if [[ "$JSON_OUTPUT" == "true" || ! -t 1 ]]; then RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; CYAN=""; NC=""; fi

[[ "$JSON_OUTPUT" == "true" ]] || {
    printf '%b\n' "${CYAN}${BOLD}"
    echo "  ================================================================="
    echo "                 TWDxOSOptimisation — macOS Hardening              "
    echo "                     v${TWDX_VERSION}  ·  TheWebDexter.com          "
    echo "  ================================================================="
    printf '%b\n' "${NC}"
}
[[ "$DRY_RUN" == "true" ]] && warn "Dry-run mode: no changes will be made."

step "Validating configuration"
validate_bool "$ENABLE_APP_FIREWALL" "ENABLE_APP_FIREWALL"
validate_bool "$ENABLE_SSH_HARDEN"   "ENABLE_SSH_HARDEN"
validate_bool "$DRY_RUN" "DRY_RUN"; validate_bool "$NON_INTERACTIVE" "NON_INTERACTIVE"; validate_bool "$JSON_OUTPUT" "JSON_OUTPUT"
success "Configuration valid"

step "Preflight"
[[ "$(uname -s)" != "Darwin" ]] && die "This script targets macOS only." "$EX_PREFLIGHT"
[[ $EUID -ne 0 ]] && die "Run via: sudo bash harden.sh" "$EX_PREFLIGHT"

# ── 1. Application Firewall ────────────────────────────────────────────────
if [[ "$ENABLE_APP_FIREWALL" == "true" ]]; then
    step "Application Firewall"
    SFW="/usr/libexec/ApplicationFirewall/socketfilterfw"
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run "$SFW --setglobalstate on ; --setstealthmode on ; --setblockall off"
        mark_step "app-firewall" "dry-run"
    elif [[ -x "$SFW" ]]; then
        "$SFW" --setglobalstate on   >/dev/null
        "$SFW" --setstealthmode on   >/dev/null
        "$SFW" --setallowsigned on   >/dev/null 2>&1 || true
        "$SFW" --setallowsignedapp on >/dev/null 2>&1 || true
        mark_step "app-firewall" "ok" "global on, stealth on"
        success "Application Firewall enabled (stealth mode on)"
    else
        mark_step "app-firewall" "failed" "socketfilterfw not found"
    fi
fi

# ── 2. SSH daemon hardening (drop-in, only if Include is supported) ───────
if [[ "$ENABLE_SSH_HARDEN" == "true" ]]; then
    step "SSH daemon hardening"
    SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
    SSH_DROPIN="${SSH_DROPIN_DIR}/99-twdxos-hardening.conf"
    if [[ -f /etc/ssh/sshd_config ]] && grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*' /etc/ssh/sshd_config; then
        if [[ "$DRY_RUN" == "true" ]]; then
            dry_run "write $SSH_DROPIN; sshd -t; launchctl kickstart -k system/com.openssh.sshd"
            mark_step "ssh" "dry-run"
        else
            mkdir -p "$SSH_DROPIN_DIR"
            cat > "$SSH_DROPIN" <<'DROPIN_EOF'
# TWDxOSOptimisation — SSH hardening (macOS). Loaded via Include sshd_config.d/*.conf
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
MaxAuthTries 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
DROPIN_EOF
            chmod 644 "$SSH_DROPIN"
            if ! sshd -t 2>/tmp/twdx-sshd-err; then
                cat /tmp/twdx-sshd-err >&2
                rm -f "$SSH_DROPIN" /tmp/twdx-sshd-err
                die "sshd config validation failed — drop-in removed." "$EX_ERR"
            fi
            rm -f /tmp/twdx-sshd-err
            if launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
                launchctl kickstart -k system/com.openssh.sshd || true
            fi
            mark_step "ssh" "ok"
            success "SSH daemon hardened via $SSH_DROPIN"
        fi
    else
        warn "sshd_config does not Include sshd_config.d/*.conf on this macOS build — skipping SSH hardening."
        warn "(Remote Login is off by default; enable it in Settings > General > Sharing only if you need SSH.)"
        mark_step "ssh" "skipped" "no Include support"
    fi
fi

# ── 3. Report-only security posture (never changed automatically) ────────
step "Security posture (report only)"

fv="unknown"
if command -v fdesetup &>/dev/null; then
    if fdesetup status 2>/dev/null | grep -q "FileVault is On"; then fv="on"; success "FileVault: On"
    else fv="off"; warn "FileVault: Off — enable in Settings > Privacy & Security (disk encryption)."; fi
fi
mark_step "filevault" "$([[ "$fv" == "on" ]] && echo ok || echo failed)" "$fv"

gk="unknown"
if spctl --status 2>/dev/null | grep -q "assessments enabled"; then
    gk="on"; success "Gatekeeper: enabled"
else
    gk="off"
    warn "Gatekeeper: disabled — re-enable in Settings > Privacy & Security"
    warn "  (the old 'spctl --master-disable/--master-enable' CLI was removed in macOS 15+)."
fi
mark_step "gatekeeper" "$([[ "$gk" == "on" ]] && echo ok || echo failed)" "$gk"

sip="unknown"
if command -v csrutil &>/dev/null; then
    if csrutil status 2>/dev/null | grep -q "enabled"; then sip="on"; success "System Integrity Protection: enabled"
    else sip="off"; warn "SIP: disabled — re-enable from Recovery (csrutil enable)."; fi
fi
mark_step "sip" "$([[ "$sip" == "on" ]] && echo ok || echo failed)" "$sip"

CONSOLE_USER=$(stat -f%Su /dev/console 2>/dev/null || echo "${SUDO_USER:-root}")
ask_pw=$(sudo -u "$CONSOLE_USER" defaults read com.apple.screensaver askForPassword 2>/dev/null || echo "0")
pw_delay=$(sudo -u "$CONSOLE_USER" defaults read com.apple.screensaver askForPasswordDelay 2>/dev/null || echo "unknown")
if [[ "$ask_pw" == "1" && "$pw_delay" != "unknown" && "$pw_delay" -le 60 ]]; then
    success "Screen lock: password required within ${pw_delay}s of sleep/screensaver"
    mark_step "screen-lock" "ok" "delay ${pw_delay}s"
else
    warn "Screen lock: not enforced or delay > 60s (askForPassword=$ask_pw delay=$pw_delay)."
    warn "  Set it in Settings > Lock Screen > Require password after screen saver begins."
    mark_step "screen-lock" "failed" "askForPassword=$ask_pw delay=$pw_delay"
fi

if (( STEP_FAILURES > 0 )); then
    warn "Hardening finished; $STEP_FAILURES posture item(s) need your attention (see above)."
    FINAL_EXIT="$EX_PARTIAL"; emit_json "partial"; exit "$EX_PARTIAL"
fi
[[ "$JSON_OUTPUT" == "true" ]] || _out "\n${GREEN}${BOLD}  Hardening complete on $(hostname 2>/dev/null || echo host)${NC}\n"
FINAL_EXIT="$EX_OK"; emit_json "ok"; exit "$EX_OK"
