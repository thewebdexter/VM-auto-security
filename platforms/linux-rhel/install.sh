#!/bin/bash
# =============================================================================
# TWDxOSOptimisation — Linux (RHEL/Fedora/CentOS) Installer
# https://github.com/TheWebDexterTech/TWDxOSOptimisation
#
# Hands-off OS maintenance for the RHEL family (RHEL, CentOS Stream, Rocky,
# AlmaLinux, Fedora):
#   • dnf-automatic security updates       • fail2ban (firewalld backend)
#   • needrestart (list-only by default)   • conditional kernel-reboot timer
#   • chrony time-sync assurance           • journald persistence + size caps
#   • weekly dnf/journal cleanup           • log rotation
#   • OPTIONAL WP-CLI module               (only when WP_PATH is set)
#
# Enterprise flags:  --json  --offline  --non-interactive  --require-signatures
#                    --strict   Exit: 0 ok · 2 usage · 3 preflight · 4 partial · 5 integrity
#
# Usage (pinned one-liner — see README for the release tag):
#   curl -fsSL https://raw.githubusercontent.com/TheWebDexterTech/TWDxOSOptimisation/v2.0.0/platforms/linux-rhel/install.sh | sudo bash
#
# Tested: Rocky 9, AlmaLinux 9, Fedora 40 — x86_64 + aarch64
# License: MIT
# =============================================================================

set -euo pipefail

TWDX_VERSION="2.0.0"
TWDX_PLATFORM="linux-rhel"
TWDX_SCRIPT="install"

EX_OK=0; EX_ERR=1; EX_USAGE=2; EX_PREFLIGHT=3; EX_PARTIAL=4; EX_INTEGRITY=5

DRY_RUN="${DRY_RUN:-false}"
OFFLINE="${OFFLINE:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"
REQUIRE_SIGNATURES="${REQUIRE_SIGNATURES:-false}"
ASSUME_YES="${ASSUME_YES:-false}"

ENABLE_DNF_AUTOMATIC="${ENABLE_DNF_AUTOMATIC:-true}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
ENABLE_NEEDRESTART="${ENABLE_NEEDRESTART:-true}"
ENABLE_AUTO_REBOOT="${ENABLE_AUTO_REBOOT:-true}"
ENABLE_TIMESYNC="${ENABLE_TIMESYNC:-true}"
ENABLE_JOURNALD_TUNING="${ENABLE_JOURNALD_TUNING:-true}"
ENABLE_CLEANUP="${ENABLE_CLEANUP:-}"

TWDX_REF="${TWDX_REF:-main}"
REPO_URL="https://raw.githubusercontent.com/TheWebDexterTech/TWDxOSOptimisation/${TWDX_REF}/platforms/${TWDX_PLATFORM}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
BUNDLE_DIR="${BUNDLE_DIR:-$SCRIPT_DIR}"

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
declare -a CLEANUP_FILES=()

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
    printf '{"tool":"twdxos","platform":"%s","script":"%s","version":"%s","result":"%s","dry_run":%s,"offline":%s,"failures":%d,"exit_code":%d,"host":"%s","timestamp":"%s","steps":[%s]}\n' \
        "$TWDX_PLATFORM" "$TWDX_SCRIPT" "$TWDX_VERSION" "$1" "$DRY_RUN" "$OFFLINE" \
        "$STEP_FAILURES" "$FINAL_EXIT" "$(json_escape "$(hostname 2>/dev/null || echo "${HOSTNAME:-unknown}")")" \
        "$(date -Iseconds)" "$joined"
}
# shellcheck disable=SC2317,SC2329  # reached only via 'trap ... EXIT'
_on_exit() {
    local rc=$?
    local f
    for f in "${CLEANUP_FILES[@]:-}"; do
        if [[ -n "$f" && -e "$f" ]]; then rm -f "$f"; fi
    done
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

die() { local code="${2:-$EX_ERR}"; _out "${RED}[fail]${NC}  $1"; FINAL_EXIT="$code"; emit_json "error"; exit "$code"; }

ask() {
    local prompt="$1" default="$2" ans
    if [[ "$NON_INTERACTIVE" == "true" || ! -c /dev/tty ]]; then printf '%s' "$default"; return 0; fi
    read -r -p "$prompt" ans < /dev/tty || ans=""
    printf '%s' "${ans:-$default}"
}

show_help() {
    cat <<'EOF'
TWDxOSOptimisation — Linux (RHEL/Fedora/CentOS) Installer

Usage: sudo bash install.sh [options]

Options:
  --dry-run/--check  --json  --offline  --non-interactive
  --require-signatures  --assume-yes  --strict  --ref <git-ref>  --help

Environment:
  WP_PATH (unset = WP module OFF)  WP_USER [apache]
  ENABLE_CLEANUP  CRON_SCHEDULE [0 3 * * 0]  REBOOT_TIME [03:30:00]
  ADMIN_EMAIL     LOG_FILE [/var/log/wp-auto-update.log]
  ENABLE_DNF_AUTOMATIC / ENABLE_FAIL2BAN / ENABLE_NEEDRESTART /
  ENABLE_AUTO_REBOOT / ENABLE_TIMESYNC / ENABLE_JOURNALD_TUNING  [true]
  OFFLINE / NON_INTERACTIVE / JSON_OUTPUT / REQUIRE_SIGNATURES /
  ASSUME_YES / DRY_RUN / TWDX_REF / BUNDLE_DIR / CURL_OPTS

SELinux: never changed by this script. If WP_PATH is outside the default
httpd docroot, run: restorecon -Rv "$WP_PATH"
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)            show_help; exit 0 ;;
        --dry-run|--check)     DRY_RUN="true" ;;
        --json)               JSON_OUTPUT="true" ;;
        --offline)            OFFLINE="true" ;;
        --non-interactive)    NON_INTERACTIVE="true" ;;
        --require-signatures) REQUIRE_SIGNATURES="true" ;;
        --assume-yes|--yes|-y) ASSUME_YES="true" ;;
        --strict)             NON_INTERACTIVE="true"; REQUIRE_SIGNATURES="true" ;;
        --ref)                shift; TWDX_REF="${1:-main}"
                              REPO_URL="https://raw.githubusercontent.com/TheWebDexterTech/TWDxOSOptimisation/${TWDX_REF}/platforms/${TWDX_PLATFORM}" ;;
        --ref=*)              TWDX_REF="${1#*=}"
                              REPO_URL="https://raw.githubusercontent.com/TheWebDexterTech/TWDxOSOptimisation/${TWDX_REF}/platforms/${TWDX_PLATFORM}" ;;
        *)                    die "Unknown argument: $1 (use --help)" "$EX_USAGE" ;;
    esac
    shift
done
if [[ "$JSON_OUTPUT" == "true" || ! -t 1 ]]; then RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; CYAN=""; NC=""; fi

[[ "$JSON_OUTPUT" == "true" ]] || {
    printf '%b\n' "${CYAN}${BOLD}"
    echo "  ================================================================="
    echo "   TWDxOSOptimisation — Linux (RHEL/Fedora/CentOS) Installer        "
    echo "                     v${TWDX_VERSION}  ·  TheWebDexter.com          "
    echo "  ================================================================="
    printf '%b\n' "${NC}"
}
[[ "$DRY_RUN" == "true" ]]         && warn "Dry-run mode: no changes will be made."
[[ "$OFFLINE" == "true" ]]         && info "Offline mode: using ${BUNDLE_DIR:-<unknown>}"
[[ "$NON_INTERACTIVE" == "true" ]] && info "Non-interactive mode."
[[ "$TWDX_REF" == "main" && "$OFFLINE" != "true" ]] && \
    warn "Unpinned ref 'main'. For production pin a release: --ref v2.0.0 (see README)."

WP_PATH="${WP_PATH:-}"
WP_USER="${WP_USER:-apache}"
REBOOT_TIME="${REBOOT_TIME:-03:30:00}"
LOG_FILE="${LOG_FILE:-/var/log/wp-auto-update.log}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
CRON_SCHEDULE="${CRON_SCHEDULE:-}"
WP_ENABLED=false
[[ -n "$WP_PATH" ]] && WP_ENABLED=true

declare -A FILE_CHECKSUMS=(
    ["configs/automatic.conf"]="a9757cc7333b3eaaac5e29a32e6118e8d820f8590870ea49630a5268fa771e3e"
    ["configs/needrestart.conf"]="2e76fcd1c11ef9f02db127e5594ca41f64aaf8b293dacedce8dc1e651ff85164"
    ["configs/auto-reboot.service"]="4c9b8b66703a09a4b99a9f2b5b475983b5a02ec39d5e02c59941450a5e4694c1"
    ["configs/auto-reboot.timer.tpl"]="e3e8e67961657bc970a9c384c53c586c73974389c374c229a5f0e33f8385625a"
    ["configs/fail2ban-jail.local"]="e2da4dcc118078300fe4710788f6592f9ea4ffd80b1811486dd48f75d9c140ab"
    ["configs/journald-twdxos.conf"]="d43d61d2327893cfbe33d9fc32a0e9d60a9515a0e0b8715a7c93d317d074d486"
    ["modules/wp-auto-update.sh.tpl"]="2dc6d56e30b8f4a2874762bdb7683c65b4d6d48350f41a986f8317ff2196bc25"
)

validate_cron_schedule() { [[ "$1" =~ ^([0-9*/,\-]+[[:space:]]+){4}[0-9*/,\-]+$ ]] || die "Invalid CRON_SCHEDULE: '$1'." "$EX_USAGE"; }
validate_integer_range() { { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= $2 && $1 <= $3 )); } || die "$4 must be $2-$3 (got '$1')" "$EX_USAGE"; }
validate_wp_path()  { [[ -n "$1" && "$1" =~ ^/[a-zA-Z0-9/_.\-]*$ ]] || die "WP_PATH '$1' invalid/unsafe." "$EX_USAGE"; }
validate_wp_user()  { [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$ ]] || die "WP_USER '$1' invalid." "$EX_USAGE"; }
validate_reboot_time() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$ ]] || die "REBOOT_TIME '$1' must be HH:MM:SS." "$EX_USAGE"; }
validate_log_path() { [[ -n "$1" && "$1" =~ ^/[a-zA-Z0-9/_.\-]*$ ]] || die "LOG_FILE '$1' invalid/unsafe." "$EX_USAGE"; }
validate_email()    { [[ -z "$1" || "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "ADMIN_EMAIL '$1' invalid." "$EX_USAGE"; }
validate_bool()     { [[ "$1" == "true" || "$1" == "false" ]] || die "$2 must be true/false (got '$1')" "$EX_USAGE"; }

PUBKEY_FILE="${BUNDLE_DIR:+$BUNDLE_DIR/}keys/twdxos-release.pub"
SIG_CAPABLE=false
if command -v minisign &>/dev/null && [[ -f "$PUBKEY_FILE" ]] && ! grep -q "REPLACE-WITH-REAL-PUBLIC-KEY" "$PUBKEY_FILE" 2>/dev/null; then
    SIG_CAPABLE=true
fi
if [[ "$REQUIRE_SIGNATURES" == "true" && "$SIG_CAPABLE" != "true" ]]; then
    die "--require-signatures set but minisign / a real keys/twdxos-release.pub are unavailable." "$EX_INTEGRITY"
fi

curl_fetch() {
    # shellcheck disable=SC2086  # CURL_OPTS is an intentional word-split opt list
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
        --connect-timeout 15 --max-time 120 ${CURL_OPTS:-} "$1" -o "$2"
}

fetch_verified() {
    local path="$1" dest="$2"
    local expected="${FILE_CHECKSUMS[$path]:-}"
    [[ -z "$expected" || "$expected" == REPLACE_* ]] && die "No usable checksum for '$path'." "$EX_INTEGRITY"
    local tmp; tmp=$(mktemp); CLEANUP_FILES+=("$tmp")
    local sig=""
    if [[ "$OFFLINE" == "true" ]]; then
        local src="$BUNDLE_DIR/$path"
        [[ -f "$src" ]] || die "Offline: '$src' not found." "$EX_PREFLIGHT"
        cp "$src" "$tmp"
        [[ -f "$src.minisig" ]] && sig="$src.minisig"
    else
        info "Fetching $path …"
        curl_fetch "$REPO_URL/$path" "$tmp" || die "Download failed for '$path'." "$EX_ERR"
        if [[ "$SIG_CAPABLE" == "true" || "$REQUIRE_SIGNATURES" == "true" ]]; then
            sig=$(mktemp); CLEANUP_FILES+=("$sig")
            if ! curl_fetch "$REPO_URL/$path.minisig" "$sig" 2>/dev/null; then
                [[ "$REQUIRE_SIGNATURES" == "true" ]] && die "No signature published for '$path'." "$EX_INTEGRITY"
                warn "No signature for '$path' — SHA256 only."
                sig=""
            fi
        fi
    fi
    local actual; actual=$(sha256sum "$tmp" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || die "Checksum mismatch for '$path' (want $expected got $actual)." "$EX_INTEGRITY"
    if [[ -n "$sig" && "$SIG_CAPABLE" == "true" ]]; then
        minisign -Vqm "$tmp" -x "$sig" -p "$PUBKEY_FILE" || die "Signature verification FAILED for '$path'." "$EX_INTEGRITY"
        info "signature OK: $path"
    fi
    install -m 644 "$tmp" "$dest"
    rm -f "$tmp"; [[ -n "$sig" && -f "$sig" ]] && rm -f "$sig"
    success "Verified & installed $(basename "$dest")"
}

step "Configuration"
if [[ "$NON_INTERACTIVE" != "true" && -c /dev/tty ]]; then
    if [[ -z "$ENABLE_CLEANUP" ]]; then
        a=$(ask "${BLUE}? Enable weekly dnf + journal cleanup? [y/N]: ${NC}" "n")
        [[ "$a" =~ ^[Yy]$ ]] && ENABLE_CLEANUP="true" || ENABLE_CLEANUP="false"
    fi
    if [[ -z "$CRON_SCHEDULE" ]]; then
        info "Job frequency: 1) Hourly  2) Daily  3) Weekly (recommended)"
        f=$(ask "  Select [1-3, default 3]: " "3")
        case "$f" in
            1) CRON_SCHEDULE="0 * * * *" ;;
            2) h=$(ask "  Hour (0-23) [3]: " "3"); validate_integer_range "$h" 0 23 Hour; CRON_SCHEDULE="0 $h * * *" ;;
            *) d=$(ask "  Day (0=Sun..6) [0]: " "0"); h=$(ask "  Hour (0-23) [3]: " "3")
               validate_integer_range "$d" 0 6 Day; validate_integer_range "$h" 0 23 Hour
               CRON_SCHEDULE="0 $h * * $d" ;;
        esac
    fi
    [[ -z "$ADMIN_EMAIL" ]] && ADMIN_EMAIL=$(ask "${BLUE}? Admin e-mail for alerts (blank = none): ${NC}" "")
fi
ENABLE_CLEANUP="${ENABLE_CLEANUP:-true}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 3 * * 0}"

step "Validating configuration"
for b in ENABLE_DNF_AUTOMATIC ENABLE_FAIL2BAN ENABLE_NEEDRESTART ENABLE_AUTO_REBOOT \
         ENABLE_TIMESYNC ENABLE_JOURNALD_TUNING ENABLE_CLEANUP DRY_RUN OFFLINE \
         NON_INTERACTIVE JSON_OUTPUT REQUIRE_SIGNATURES ASSUME_YES; do
    validate_bool "${!b}" "$b"
done
validate_cron_schedule "$CRON_SCHEDULE"
validate_reboot_time "$REBOOT_TIME"
validate_email "$ADMIN_EMAIL"
if [[ "$WP_ENABLED" == "true" ]]; then
    validate_wp_path "$WP_PATH"; validate_wp_user "$WP_USER"; validate_log_path "$LOG_FILE"
fi
success "Configuration valid"

step "Preflight"
[[ $EUID -ne 0 ]] && die "Run as root (sudo)." "$EX_PREFLIGHT"
command -v dnf &>/dev/null || die "dnf not found — this installer targets the RHEL family." "$EX_PREFLIGHT"
[[ "$OFFLINE" == "true" && ! -d "$BUNDLE_DIR/configs" ]] && die "Offline: '$BUNDLE_DIR/configs' missing. Set BUNDLE_DIR." "$EX_PREFLIGHT"

if [[ "$DRY_RUN" != "true" && "$OFFLINE" != "true" ]]; then
    command -v curl      &>/dev/null || dnf install -y -q curl || die "cannot install curl" "$EX_PREFLIGHT"
    command -v sha256sum &>/dev/null || dnf install -y -q coreutils || die "cannot install coreutils" "$EX_PREFLIGHT"
fi

OS_ID="unknown"; OS_VERSION="0"
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release; OS_ID="${ID:-unknown}"; OS_VERSION="${VERSION_ID:-0}"
fi
NEEDS_EPEL=true
case "$OS_ID" in
    fedora) NEEDS_EPEL=false ;;
    rhel|centos|rocky|almalinux) NEEDS_EPEL=true ;;
    *) warn "Untested distro '$OS_ID $OS_VERSION' — proceeding" ;;
esac

if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
    info "SELinux is Enforcing — this script never changes SELinux mode/policy."
fi

if [[ "$WP_ENABLED" == "true" ]]; then
    info "WordPress module ENABLED (path $WP_PATH, owner $WP_USER)"
    [[ -f "$WP_PATH/wp-includes/version.php" ]] || warn "No WordPress at $WP_PATH — WP cron job installs but exits 0 until it exists."
else
    info "WordPress module disabled (set WP_PATH to enable)"
fi

# ── 0. EPEL ────────────────────────────────────────────────────────────────
if [[ "$NEEDS_EPEL" == "true" && ( "$ENABLE_FAIL2BAN" == "true" || "$ENABLE_NEEDRESTART" == "true" ) ]]; then
    step "EPEL repository"
    if [[ "$DRY_RUN" == "true" || "$OFFLINE" == "true" ]]; then
        dry_run "dnf install epel-release"; mark_step "epel" "dry-run"
    else
        if dnf install -y -q epel-release; then mark_step "epel" "ok"; else mark_step "epel" "failed"; fi
    fi
fi

# ── 1. dnf-automatic (security only) ─────────────────────────────────────
step "Unattended security upgrades (dnf-automatic)"
if [[ "$ENABLE_DNF_AUTOMATIC" != "true" ]]; then
    mark_step "dnf-automatic" "skipped" "disabled"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "dnf install dnf-automatic; install verified configs/automatic.conf; enable dnf-automatic-install.timer"
    mark_step "dnf-automatic" "dry-run"
else
    if { [[ "$OFFLINE" == "true" ]] || dnf install -y -q dnf-automatic; }; then
        fetch_verified "configs/automatic.conf" /etc/dnf/automatic.conf
        if [[ -n "$ADMIN_EMAIL" ]]; then
            sed -i "s|^emit_via = .*|emit_via = stdio, email|; s|^email_to = .*|email_to = ${ADMIN_EMAIL}|" /etc/dnf/automatic.conf || true
            grep -q '^email_to' /etc/dnf/automatic.conf || printf '\n[email]\nemail_to = %s\n' "$ADMIN_EMAIL" >> /etc/dnf/automatic.conf
        fi
        systemctl enable --now dnf-automatic-install.timer &>/dev/null || true
        mark_step "dnf-automatic" "ok" "security only"
        success "dnf-automatic active (security advisories only)"
    else
        mark_step "dnf-automatic" "failed" "package install failed"
    fi
fi

# ── 2. fail2ban ────────────────────────────────────────────────────────
step "Intrusion prevention (fail2ban)"
if [[ "$ENABLE_FAIL2BAN" != "true" ]]; then
    mark_step "fail2ban" "skipped" "disabled"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "dnf install fail2ban; install verified configs/fail2ban-jail.local"
    mark_step "fail2ban" "dry-run"
else
    if { [[ "$OFFLINE" == "true" ]] || dnf install -y -q fail2ban; }; then
        fetch_verified "configs/fail2ban-jail.local" /etc/fail2ban/jail.local
        chmod 644 /etc/fail2ban/jail.local
        systemctl enable fail2ban &>/dev/null || true
        systemctl restart fail2ban || warn "fail2ban restart failed"
        mark_step "fail2ban" "ok"
        success "fail2ban active (ignoreip = loopback only — add trusted CIDRs in jail.local)"
    else
        mark_step "fail2ban" "failed" "package install failed"
    fi
fi

# ── 3. needrestart ───────────────────────────────────────────────────
step "Service restart policy (needrestart)"
if [[ "$ENABLE_NEEDRESTART" != "true" ]]; then
    mark_step "needrestart" "skipped" "disabled"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "dnf install needrestart; install verified configs/needrestart.conf (list-only)"
    mark_step "needrestart" "dry-run"
else
    if { [[ "$OFFLINE" == "true" ]] || dnf install -y -q needrestart; }; then
        fetch_verified "configs/needrestart.conf" /etc/needrestart/needrestart.conf
        mark_step "needrestart" "ok" "list-only"
        success "needrestart configured (reports; does not auto-restart)"
    else
        mark_step "needrestart" "failed" "package install failed"
    fi
fi

# ── 4. Kernel-reboot timer ─────────────────────────────────────────
step "Conditional kernel-reboot timer"
if [[ "$ENABLE_AUTO_REBOOT" != "true" ]]; then
    mark_step "auto-reboot" "skipped" "disabled"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "dnf install dnf-utils; install auto-reboot.service + timer (OnCalendar $REBOOT_TIME)"
    mark_step "auto-reboot" "dry-run"
else
    [[ "$OFFLINE" == "true" ]] || dnf install -y -q dnf-utils || warn "dnf-utils install failed (needs-restarting may be unavailable)"
    svc=$(mktemp); tmr=$(mktemp); CLEANUP_FILES+=("$svc" "$tmr")
    fetch_verified "configs/auto-reboot.service"   "$svc"
    fetch_verified "configs/auto-reboot.timer.tpl" "$tmr"
    install -m 644 "$svc" /etc/systemd/system/auto-reboot.service
    sed "s|__REBOOT_TIME__|${REBOOT_TIME}|g" "$tmr" > /etc/systemd/system/auto-reboot.timer
    chmod 644 /etc/systemd/system/auto-reboot.timer
    systemctl daemon-reload
    systemctl enable --now auto-reboot.timer &>/dev/null || true
    rm -f "$svc" "$tmr"
    mark_step "auto-reboot" "ok" "$REBOOT_TIME"
    success "auto-reboot.timer scheduled ($REBOOT_TIME, 5-min grace, only when 'dnf needs-restarting -r' says so)"
fi

# ── 5. Time sync ──────────────────────────────────────────────────
step "Time synchronisation"
if [[ "$ENABLE_TIMESYNC" != "true" ]]; then
    mark_step "timesync" "skipped" "disabled"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "dnf install chrony; enable --now chronyd"
    mark_step "timesync" "dry-run"
else
    [[ "$OFFLINE" == "true" ]] || command -v chronyd &>/dev/null || dnf install -y -q chrony || true
    if systemctl enable --now chronyd &>/dev/null; then
        mark_step "timesync" "ok" "chronyd"
        success "chronyd enabled"
    elif command -v timedatectl &>/dev/null && timedatectl set-ntp true 2>/dev/null; then
        mark_step "timesync" "ok" "timedatectl set-ntp"
        success "NTP enabled via timedatectl"
    else
        mark_step "timesync" "failed" "no chronyd / timedatectl"
    fi
fi

# ── 6. journald ─────────────────────────────────────────────────
step "journald persistence & retention"
if [[ "$ENABLE_JOURNALD_TUNING" != "true" ]]; then
    mark_step "journald" "skipped" "disabled"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "install verified configs/journald-twdxos.conf → /etc/systemd/journald.conf.d/99-twdxos.conf"
    mark_step "journald" "dry-run"
else
    mkdir -p /etc/systemd/journald.conf.d
    fetch_verified "configs/journald-twdxos.conf" /etc/systemd/journald.conf.d/99-twdxos.conf
    systemctl restart systemd-journald || warn "journald restart failed"
    mark_step "journald" "ok"
    success "journald: persistent, capped, 1-month retention"
fi

# ── 7. Cleanup script ─────────────────────────────────────────
if [[ "$ENABLE_CLEANUP" == "true" ]]; then
    step "Weekly cleanup script"
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run "write /usr/local/bin/vm-system-cleanup.sh"; mark_step "cleanup-script" "dry-run"
    else
        cat > /usr/local/bin/vm-system-cleanup.sh <<'EOF'
#!/bin/bash
set -uo pipefail
LOG="/var/log/vm-system-cleanup.log"
{
    echo "=== $(date -Iseconds) system cleanup ==="
    dnf autoremove -y || true
    dnf clean all || true
    journalctl --vacuum-time=30d --vacuum-size=500M || true
    echo "=== done ==="
} >> "$LOG" 2>&1
EOF
        chmod 750 /usr/local/bin/vm-system-cleanup.sh
        [[ -f /var/log/vm-system-cleanup.log ]] || install -m 640 -o root -g adm /dev/null /var/log/vm-system-cleanup.log 2>/dev/null || true
        mark_step "cleanup-script" "ok"
        success "cleanup script generated"
    fi
fi

# ── 8. Log rotation ───────────────────────────────────────────
step "Log rotation"
if [[ "$DRY_RUN" == "true" ]]; then
    dry_run "write /etc/logrotate.d/twdxos"; mark_step "logrotate" "dry-run"
else
    {
        [[ "$WP_ENABLED" == "true" ]] && echo "$LOG_FILE"
        echo "/var/log/vm-system-cleanup.log {"
        echo "    weekly"; echo "    rotate 8"; echo "    compress"; echo "    delaycompress"
        echo "    missingok"; echo "    notifempty"; echo "    create 0640 root adm"
        echo "}"
    } > /etc/logrotate.d/twdxos
    chmod 644 /etc/logrotate.d/twdxos
    mark_step "logrotate" "ok"
    success "log rotation configured"
fi

# ── 9. Optional WP module ────────────────────────────────────
if [[ "$WP_ENABLED" == "true" ]]; then
    step "WP-CLI"
    WP_CLI_PINNED_SHA512="${WP_CLI_PINNED_SHA512:-}"
    if command -v wp &>/dev/null; then
        info "WP-CLI already present"; mark_step "wp-cli" "skipped" "already installed"
    elif [[ "$DRY_RUN" == "true" ]]; then
        dry_run "download + verify wp-cli.phar"; mark_step "wp-cli" "dry-run"
    elif [[ "$OFFLINE" == "true" ]]; then
        if [[ -f "$BUNDLE_DIR/vendor/wp-cli.phar" ]]; then
            install -m 755 "$BUNDLE_DIR/vendor/wp-cli.phar" /usr/local/bin/wp; mark_step "wp-cli" "ok" "from bundle"
        else
            warn "Offline: $BUNDLE_DIR/vendor/wp-cli.phar not found"; mark_step "wp-cli" "failed" "missing in bundle"
        fi
    else
        tmp=$(mktemp); CLEANUP_FILES+=("$tmp")
        curl_fetch "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar" "$tmp" || die "WP-CLI download failed." "$EX_ERR"
        actual=$(sha512sum "$tmp" | awk '{print $1}')
        if [[ -n "$WP_CLI_PINNED_SHA512" ]]; then
            [[ "$actual" == "$WP_CLI_PINNED_SHA512" ]] || die "WP-CLI SHA512 != pinned." "$EX_INTEGRITY"
        else
            up_tmp=$(mktemp); CLEANUP_FILES+=("$up_tmp")
            curl_fetch "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512" "$up_tmp" || die "cannot fetch upstream checksum" "$EX_ERR"
            up=$(awk '{print $1}' "$up_tmp"); rm -f "$up_tmp"
            [[ "$actual" == "$up" ]] || die "WP-CLI SHA512 mismatch vs upstream." "$EX_INTEGRITY"
            warn "WP-CLI verified against upstream .sha512 only (TOFU). Set WP_CLI_PINNED_SHA512 to harden."
        fi
        install -m 755 "$tmp" /usr/local/bin/wp; rm -f "$tmp"
        mark_step "wp-cli" "ok"; success "WP-CLI installed and verified"
    fi

    step "WordPress update script"
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run "render modules/wp-auto-update.sh.tpl → /usr/local/bin/wp-auto-update.sh"; mark_step "wp-update-script" "dry-run"
    else
        tmp=$(mktemp); CLEANUP_FILES+=("$tmp")
        fetch_verified "modules/wp-auto-update.sh.tpl" "$tmp"
        sed -e "s|__WP_PATH__|${WP_PATH}|g" -e "s|__WP_USER__|${WP_USER}|g" -e "s|__LOG_FILE__|${LOG_FILE}|g" \
            "$tmp" > /usr/local/bin/wp-auto-update.sh
        chmod 750 /usr/local/bin/wp-auto-update.sh; rm -f "$tmp"
        [[ -f "$LOG_FILE" ]] || install -m 640 -o root -g adm /dev/null "$LOG_FILE" 2>/dev/null || true
        mark_step "wp-update-script" "ok"; success "wp-auto-update.sh installed"
        if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
            warn "SELinux Enforcing: if $WP_PATH is outside the httpd docroot, run: restorecon -Rv \"$WP_PATH\""
        fi
    fi
fi

# ── 10. Cron ────────────────────────────────────────────────
step "Schedules"
if [[ "$DRY_RUN" != "true" && "$OFFLINE" != "true" ]] && ! rpm -q cronie &>/dev/null; then
    if dnf install -y -q cronie; then
        systemctl enable --now crond &>/dev/null || true
    else
        warn "cronie install failed — /etc/cron.d/twdxos will not run without a cron daemon"
    fi
fi
CRON_FILE="/etc/cron.d/twdxos"
CLEANUP_SCHEDULE=$(echo "$CRON_SCHEDULE" | sed 's/^[0-9*,/\-]*/30/')
if [[ "$WP_ENABLED" != "true" && "$ENABLE_CLEANUP" != "true" ]]; then
    [[ "$DRY_RUN" == "true" ]] || rm -f "$CRON_FILE"
    mark_step "cron" "skipped" "nothing to schedule"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "write $CRON_FILE ('$CRON_SCHEDULE')"; mark_step "cron" "dry-run"
else
    {
        echo "# TWDxOSOptimisation (linux-rhel) — managed by install.sh; re-run to update."
        echo "SHELL=/bin/bash"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"
        if [[ -n "$ADMIN_EMAIL" ]]; then echo "MAILTO=$ADMIN_EMAIL"; else echo "MAILTO="; fi
        [[ "$WP_ENABLED" == "true" ]]     && echo "$CRON_SCHEDULE root /usr/local/bin/wp-auto-update.sh"
        [[ "$ENABLE_CLEANUP" == "true" ]] && echo "$CLEANUP_SCHEDULE root /usr/local/bin/vm-system-cleanup.sh"
    } > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    mark_step "cron" "ok" "$CRON_SCHEDULE"
    success "cron written to $CRON_FILE"
fi

if (( STEP_FAILURES > 0 )); then
    warn "Completed with $STEP_FAILURES failed step(s)."
    FINAL_EXIT="$EX_PARTIAL"; emit_json "partial"; exit "$EX_PARTIAL"
fi
if [[ "$JSON_OUTPUT" != "true" ]]; then
    wp_state="disabled"; [[ "$WP_ENABLED" == "true" ]] && wp_state="enabled"
    _out "\n${GREEN}${BOLD}  TWDxOSOptimisation ${TWDX_VERSION} installed on $(hostname 2>/dev/null || echo host)${NC}"
    _out "  WordPress module: ${wp_state}\n"
fi
FINAL_EXIT="$EX_OK"; emit_json "ok"; exit "$EX_OK"
