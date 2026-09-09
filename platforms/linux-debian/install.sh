#!/bin/bash
# =============================================================================
# TWDxOSOptimisation — Linux (Debian/Ubuntu) Installer
# https://github.com/TheWebDexterTech/TWDxOSOptimisation
#
# Hands-off OS maintenance for headless Debian/Ubuntu servers:
#   • unattended security updates          • fail2ban intrusion prevention
#   • needrestart (list-only by default)   • conditional kernel-reboot timer
#   • time synchronisation assurance       • journald persistence + size caps
#   • weekly apt/journal cleanup           • log rotation
#   • OPTIONAL WP-CLI auto-update module   (only when WP_PATH is set)
#
# Enterprise features:
#   --json               machine-readable summary on stdout, logs on stderr
#   --offline            no network fetches; use files bundled beside this script
#   --non-interactive    never prompt; fail closed on unresolved decisions
#   --require-signatures  minisign signature verification is mandatory
#   --strict             = --non-interactive --require-signatures
#   Stable exit codes:   0 ok · 2 usage · 3 preflight · 4 partial · 5 integrity
#
# Usage (pinned one-liner — see README for the current release tag):
#   curl -fsSL https://raw.githubusercontent.com/TheWebDexterTech/TWDxOSOptimisation/v2.0.0/platforms/linux-debian/install.sh | sudo bash
#
# Tested: Ubuntu 24.04 LTS / Debian 12 — aarch64 + x86_64
# License: MIT
# =============================================================================

set -euo pipefail

TWDX_VERSION="2.0.0"
TWDX_PLATFORM="linux-debian"
TWDX_SCRIPT="install"

# ── Exit-code contract ───────────────────────────────────────────────────────
EX_OK=0            # success
EX_ERR=1           # unexpected/internal error
EX_USAGE=2         # invalid configuration / usage
EX_PREFLIGHT=3     # preflight failed (OS, privileges, offline prereqs)
EX_PARTIAL=4       # one or more steps failed; others applied
EX_INTEGRITY=5     # checksum or signature verification failed

# ── Global toggles (flag or environment) ─────────────────────────────────────
DRY_RUN="${DRY_RUN:-false}"
OFFLINE="${OFFLINE:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"
REQUIRE_SIGNATURES="${REQUIRE_SIGNATURES:-false}"
ASSUME_YES="${ASSUME_YES:-false}"

# ── Feature toggles (enterprise environments often centralise these) ─────────
ENABLE_UNATTENDED_UPGRADES="${ENABLE_UNATTENDED_UPGRADES:-true}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
ENABLE_NEEDRESTART="${ENABLE_NEEDRESTART:-true}"
ENABLE_AUTO_REBOOT="${ENABLE_AUTO_REBOOT:-true}"
ENABLE_TIMESYNC="${ENABLE_TIMESYNC:-true}"
ENABLE_JOURNALD_TUNING="${ENABLE_JOURNALD_TUNING:-true}"
ENABLE_CLEANUP="${ENABLE_CLEANUP:-}"          # resolved later (prompt/default)

# ── Ref pinning ──────────────────────────────────────────────────────────────
TWDX_REF="${TWDX_REF:-main}"
REPO_URL="https://raw.githubusercontent.com/TheWebDexterTech/TWDxOSOptimisation/${TWDX_REF}/platforms/${TWDX_PLATFORM}"

# ── Bundle dir (for --offline) ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
BUNDLE_DIR="${BUNDLE_DIR:-$SCRIPT_DIR}"

# ── Colours (disabled for non-tty / --json) ──────────────────────────────────
if [[ -t 1 && "${JSON_OUTPUT}" != "true" ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; CYAN=""; NC=""
fi

# ── Logging (human text → stderr when --json, else stdout) ───────────────────
_out() { if [[ "$JSON_OUTPUT" == "true" ]]; then printf '%b\n' "$*" >&2; else printf '%b\n' "$*"; fi; }
info()    { _out "${BLUE}[info]${NC}  $*"; }
success() { _out "${GREEN}[ ok ]${NC}  $*"; }
warn()    { _out "${YELLOW}[warn]${NC}  $*"; }
step()    { _out "\n${BOLD}▸ $*${NC}"; }
dry_run() { _out "${YELLOW}[dry-run]${NC}  Would: $*"; }

# ── JSON summary machinery ───────────────────────────────────────────────────
declare -a JSON_STEPS=()
STEP_FAILURES=0
FINAL_EXIT=0
_JSON_EMITTED=""
declare -a CLEANUP_FILES=()

json_escape() {
    local s=${1-}
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}
    printf '%s' "$s"
}
json_step() {
    printf '{"name":"%s","status":"%s","detail":"%s"}' \
        "$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "${3:-}")"
}
mark_step() {   # mark_step <name> <ok|failed|skipped|dry-run> [detail]
    JSON_STEPS+=("$(json_step "$1" "$2" "${3:-}")")
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

die() {   # die <message> [exit_code]
    local code="${2:-$EX_ERR}"
    _out "${RED}[fail]${NC}  $1"
    FINAL_EXIT="$code"
    emit_json "error"
    exit "$code"
}

# ── Interactive prompt (honours --non-interactive) ─────────────────────────
ask() {   # ask <prompt> <default> -> echoes answer (default when non-interactive)
    local prompt="$1" default="$2" ans
    if [[ "$NON_INTERACTIVE" == "true" || ! -c /dev/tty ]]; then printf '%s' "$default"; return 0; fi
    read -r -p "$prompt" ans < /dev/tty || ans=""
    printf '%s' "${ans:-$default}"
}

show_help() {
    cat <<'EOF'
TWDxOSOptimisation — Linux (Debian/Ubuntu) Installer

Usage:
  sudo bash install.sh [options]

Options:
  --dry-run, --check      Preview every change without applying it
  --json                  Emit a JSON result object on stdout (logs go to stderr)
  --offline               Do not fetch anything; use files beside this script
  --non-interactive       Never prompt; fail closed on unresolved decisions
  --require-signatures    minisign signature verification is mandatory
  --assume-yes            Auto-accept optional prompts
  --strict                = --non-interactive --require-signatures
  --ref <git-ref>         Fetch configs from this tag/branch/SHA (default: main)
  --help, -h              This help

Environment variables:
  WP_PATH         Absolute path to a WordPress root. UNSET = WP module disabled.
  WP_USER         OS user owning WP files                     [www-data]
  ENABLE_CLEANUP  Weekly apt + journal cleanup                [prompt / true]
  CRON_SCHEDULE   Schedule for WP update / cleanup jobs       [0 3 * * 0]
  REBOOT_TIME     Nightly kernel-reboot check (HH:MM:SS)      [03:30:00]
  ADMIN_EMAIL     MAILTO for cron + Unattended-Upgrade::Mail  (empty)
  LOG_FILE        WP update log path                          [/var/log/wp-auto-update.log]

  ENABLE_UNATTENDED_UPGRADES / ENABLE_FAIL2BAN / ENABLE_NEEDRESTART /
  ENABLE_AUTO_REBOOT / ENABLE_TIMESYNC / ENABLE_JOURNALD_TUNING   [true]

  OFFLINE / NON_INTERACTIVE / JSON_OUTPUT / REQUIRE_SIGNATURES /
  ASSUME_YES / DRY_RUN / TWDX_REF / BUNDLE_DIR / CURL_OPTS

Examples:
  sudo bash install.sh --dry-run
  sudo WP_PATH=/srv/wp ADMIN_EMAIL=ops@example.com bash install.sh
  sudo bash install.sh --strict --json
  sudo BUNDLE_DIR=/opt/twdx bash install.sh --offline --non-interactive
EOF
}

# ── Arg parsing ──────────────────────────────────────────────────────────────
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

# Re-evaluate colours now that --json may have been set as a flag.
if [[ "$JSON_OUTPUT" == "true" || ! -t 1 ]]; then
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; CYAN=""; NC=""
fi

[[ "$JSON_OUTPUT" == "true" ]] || {
    printf '%b\n' "${CYAN}${BOLD}"
    echo "  ================================================================="
    echo "        TWDxOSOptimisation — Linux (Debian/Ubuntu) Installer        "
    echo "                     v${TWDX_VERSION}  ·  TheWebDexter.com          "
    echo "  ================================================================="
    printf '%b\n' "${NC}"
}
[[ "$DRY_RUN" == "true" ]]        && warn "Dry-run mode: no changes will be made."
[[ "$OFFLINE" == "true" ]]        && info "Offline mode: fetching nothing; using ${BUNDLE_DIR:-<unknown>}"
[[ "$NON_INTERACTIVE" == "true" ]] && info "Non-interactive mode: prompts auto-resolve to safe defaults."
[[ "$TWDX_REF" == "main" && "$OFFLINE" != "true" ]] && \
    warn "Unpinned ref 'main'. For production pin a release: --ref v2.0.0 (see README)."

# ── Default configuration ────────────────────────────────────────────────────
WP_PATH="${WP_PATH:-}"
WP_USER="${WP_USER:-www-data}"
REBOOT_TIME="${REBOOT_TIME:-03:30:00}"
LOG_FILE="${LOG_FILE:-/var/log/wp-auto-update.log}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
CRON_SCHEDULE="${CRON_SCHEDULE:-}"
WP_ENABLED=false
[[ -n "$WP_PATH" ]] && WP_ENABLED=true

# ── SHA256 digests of every remote file this installer fetches ───────────────
declare -A FILE_CHECKSUMS=(
    ["configs/50unattended-upgrades"]="3d3eb0eb194947fae50df63dc8abe62d2109f66490a54c4cde5bc1f1449ea285"
    ["configs/20auto-upgrades"]="d742d9edfb7f0e166ee6b847294f4933db30a1cbacbc45adaca051f1b0ed69bb"
    ["configs/needrestart.conf"]="9590f18ad2b1de31e3b67f60321880db4212e0b4ce8d1b3609a13f73de8d12a7"
    ["configs/auto-reboot.service"]="c6be3f85451af2411dc9ad5bc39689bb053954d9ce4ded398efdde207237b0b8"
    ["configs/auto-reboot.timer.tpl"]="e3e8e67961657bc970a9c384c53c586c73974389c374c229a5f0e33f8385625a"
    ["configs/fail2ban-jail.local"]="78a82e2e844364a4da138c985f8b754b64dbe55745ebb614b69fee1b6d64bc74"
    ["configs/journald-twdxos.conf"]="b77768d0b0f856eacc6afec76aae3b690735c059992917fe12a8bec89458482f"
    ["modules/wp-auto-update.sh.tpl"]="a45818b9e577242016aabe022a0c21b4c5b0c1e533e48990a6e39ce59d99c10a"
)

# ── Input validation ─────────────────────────────────────────────────────────
validate_cron_schedule() {
    local sched="$1"
    [[ "$sched" =~ ^([0-9*/,\-]+[[:space:]]+){4}[0-9*/,\-]+$ ]] || \
        die "Invalid CRON_SCHEDULE: '$sched' (need 5 standard cron fields, e.g. '0 3 * * 0')." "$EX_USAGE"
}
validate_integer_range() {
    local val="$1" min="$2" max="$3" name="$4"
    { [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min && val <= max )); } || \
        die "$name must be an integer between $min and $max (got: '$val')" "$EX_USAGE"
}
validate_wp_path() {
    [[ -n "$1" ]] || die "WP_PATH must not be empty." "$EX_USAGE"
    [[ "$1" =~ ^/[a-zA-Z0-9/_.\-]*$ ]] || \
        die "WP_PATH '$1' contains unsafe characters (allowed: letters digits / _ . -)" "$EX_USAGE"
}
validate_wp_user() {
    [[ -n "$1" ]] || die "WP_USER must not be empty." "$EX_USAGE"
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$ ]] || die "WP_USER '$1' is not a valid Unix username." "$EX_USAGE"
}
validate_reboot_time() {
    [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$ ]] || \
        die "REBOOT_TIME '$1' must be HH:MM:SS (e.g. 03:30:00)." "$EX_USAGE"
}
validate_log_path() {
    [[ -n "$1" ]] || die "LOG_FILE must not be empty." "$EX_USAGE"
    [[ "$1" =~ ^/[a-zA-Z0-9/_.\-]*$ ]] || die "LOG_FILE '$1' contains unsafe characters." "$EX_USAGE"
}
validate_email() {
    [[ -z "$1" ]] && return 0
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || \
        die "ADMIN_EMAIL '$1' is not a valid e-mail address." "$EX_USAGE"
}
validate_bool() {
    [[ "$1" == "true" || "$1" == "false" ]] || die "$2 must be 'true' or 'false' (got: '$1')" "$EX_USAGE"
}

# ── Signature verification (minisign, optional unless --require-signatures) ──
PUBKEY_FILE="${BUNDLE_DIR:+$BUNDLE_DIR/}keys/twdxos-release.pub"
SIG_CAPABLE=false
if command -v minisign &>/dev/null && [[ -f "$PUBKEY_FILE" ]] && ! grep -q "REPLACE-WITH-REAL-PUBLIC-KEY" "$PUBKEY_FILE" 2>/dev/null; then
    SIG_CAPABLE=true
fi
if [[ "$REQUIRE_SIGNATURES" == "true" && "$SIG_CAPABLE" != "true" ]]; then
    die "--require-signatures set but minisign and/or a real keys/twdxos-release.pub are unavailable." "$EX_INTEGRITY"
fi

curl_fetch() {   # curl_fetch <url> <dest>
    # shellcheck disable=SC2086  # CURL_OPTS is an intentional word-split opt list
    curl -fsSL --proto '=https' --tlsv1.2 \
        --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 \
        ${CURL_OPTS:-} "$1" -o "$2"
}

fetch_verified() {   # fetch_verified <repo-relative-path> <dest>
    local path="$1" dest="$2"
    local expected="${FILE_CHECKSUMS[$path]:-}"
    [[ -z "$expected" || "$expected" == REPLACE_* ]] && \
        die "No usable checksum registered for '$path'." "$EX_INTEGRITY"

    local tmp; tmp=$(mktemp); CLEANUP_FILES+=("$tmp")
    local sig=""

    if [[ "$OFFLINE" == "true" ]]; then
        local src="$BUNDLE_DIR/$path"
        [[ -f "$src" ]] || die "Offline mode: '$src' not found beside the script." "$EX_PREFLIGHT"
        cp "$src" "$tmp"
        [[ -f "$src.minisig" ]] && sig="$src.minisig"
    else
        info "Fetching $path …"
        curl_fetch "$REPO_URL/$path" "$tmp" || die "Download failed for '$path'." "$EX_ERR"
        if [[ "$SIG_CAPABLE" == "true" || "$REQUIRE_SIGNATURES" == "true" ]]; then
            sig=$(mktemp); CLEANUP_FILES+=("$sig")
            if ! curl_fetch "$REPO_URL/$path.minisig" "$sig" 2>/dev/null; then
                [[ "$REQUIRE_SIGNATURES" == "true" ]] && die "No signature published for '$path'." "$EX_INTEGRITY"
                warn "No signature for '$path' — falling back to SHA256 only."
                sig=""
            fi
        fi
    fi

    local actual; actual=$(sha256sum "$tmp" | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        die "Checksum mismatch for '$path' (expected $expected, got $actual). Aborting — possible tampering." "$EX_INTEGRITY"
    fi

    if [[ -n "$sig" ]]; then
        if [[ "$SIG_CAPABLE" == "true" ]]; then
            minisign -Vqm "$tmp" -x "$sig" -p "$PUBKEY_FILE" \
                || die "Signature verification FAILED for '$path'." "$EX_INTEGRITY"
            info "signature OK: $path"
        elif [[ "$REQUIRE_SIGNATURES" == "true" ]]; then
            die "Cannot verify signature for '$path' (minisign/pubkey missing)." "$EX_INTEGRITY"
        fi
    fi

    install -m 644 "$tmp" "$dest"
    rm -f "$tmp"; sig="${sig:-}"; [[ -n "$sig" && -f "$sig" ]] && rm -f "$sig"
    success "Verified & installed $(basename "$dest")"
}

# ── Interactive configuration ────────────────────────────────────────────────
step "Configuration"

if [[ "$NON_INTERACTIVE" != "true" && -c /dev/tty ]]; then
    if [[ -z "$ENABLE_CLEANUP" ]]; then
        ans=$(ask "${BLUE}? Enable weekly apt + journal cleanup? [y/N]: ${NC}" "n")
        [[ "$ans" =~ ^[Yy]$ ]] && ENABLE_CLEANUP="true" || ENABLE_CLEANUP="false"
    fi
    if [[ -z "$CRON_SCHEDULE" ]]; then
        echo ""
        info "How often should the WP update / cleanup jobs run?"
        echo "  1) Hourly   2) Daily   3) Weekly (recommended)"
        freq=$(ask "  Select [1-3, default 3]: " "3")
        case "$freq" in
            1) CRON_SCHEDULE="0 * * * *" ;;
            2) hour=$(ask "  Hour of day (0-23) [3]: " "3")
               validate_integer_range "$hour" 0 23 "Hour"
               CRON_SCHEDULE="0 $hour * * *" ;;
            *) dow=$(ask "  Day of week (0=Sun..6=Sat) [0]: " "0")
               hour=$(ask "  Hour of day (0-23) [3]: " "3")
               validate_integer_range "$dow" 0 6 "Day of week"
               validate_integer_range "$hour" 0 23 "Hour"
               CRON_SCHEDULE="0 $hour * * $dow" ;;
        esac
    fi
    if [[ -z "$ADMIN_EMAIL" ]]; then
        ADMIN_EMAIL=$(ask "${BLUE}? Admin e-mail for update/cron alerts (blank = none): ${NC}" "")
    fi
fi

ENABLE_CLEANUP="${ENABLE_CLEANUP:-true}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 3 * * 0}"

# ── Validate everything before touching disk ─────────────────────────────────
step "Validating configuration"
for b in ENABLE_UNATTENDED_UPGRADES ENABLE_FAIL2BAN ENABLE_NEEDRESTART \
         ENABLE_AUTO_REBOOT ENABLE_TIMESYNC ENABLE_JOURNALD_TUNING ENABLE_CLEANUP \
         DRY_RUN OFFLINE NON_INTERACTIVE JSON_OUTPUT REQUIRE_SIGNATURES ASSUME_YES; do
    validate_bool "${!b}" "$b"
done
validate_cron_schedule "$CRON_SCHEDULE"
validate_reboot_time   "$REBOOT_TIME"
validate_email         "$ADMIN_EMAIL"
if [[ "$WP_ENABLED" == "true" ]]; then
    validate_wp_path "$WP_PATH"
    validate_wp_user "$WP_USER"
    validate_log_path "$LOG_FILE"
fi
success "Configuration valid"

# ── Preflight ───────────────────────────────────────────────────────────────
step "Preflight"
[[ $EUID -ne 0 ]] && die "Run as root (sudo)." "$EX_PREFLIGHT"
[[ "$OFFLINE" == "true" && ! -d "$BUNDLE_DIR/configs" ]] && \
    die "Offline mode: '$BUNDLE_DIR/configs' not found. Set BUNDLE_DIR to the checkout." "$EX_PREFLIGHT"

if [[ "$DRY_RUN" != "true" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    if [[ "$OFFLINE" != "true" ]]; then
        apt-get update -q || warn "apt-get update reported errors — continuing"
    fi
    for pkg_cmd in "curl:curl" "sha256sum:coreutils" "lsb_release:lsb-release"; do
        cmd="${pkg_cmd%%:*}"; pkg="${pkg_cmd##*:}"
        command -v "$cmd" &>/dev/null && continue
        [[ "$OFFLINE" == "true" ]] && die "Offline mode needs '$cmd' preinstalled (package $pkg)." "$EX_PREFLIGHT"
        apt-get install -y -q "$pkg" || die "Could not install prerequisite '$pkg'." "$EX_PREFLIGHT"
    done
fi

OS=$(lsb_release -si 2>/dev/null || echo "Unknown")
VER=$(lsb_release -sr 2>/dev/null || echo "0")
[[ "$OS" =~ ^(Ubuntu|Debian)$ ]] || warn "Tested on Ubuntu/Debian — proceeding anyway on $OS $VER"

if [[ "$WP_ENABLED" == "true" ]]; then
    info "WordPress module: ENABLED (path: $WP_PATH, owner: $WP_USER)"
    [[ -f "$WP_PATH/wp-includes/version.php" ]] || \
        warn "No WordPress found at $WP_PATH — the WP cron job will be installed but exit 0 until it exists."
else
    info "WordPress module: disabled (set WP_PATH to enable it)"
fi

# ── 1. Unattended security upgrades ─────────────────────────────────────────
step "Unattended security upgrades"
if [[ "$ENABLE_UNATTENDED_UPGRADES" != "true" ]]; then
    mark_step "unattended-upgrades" "skipped" "ENABLE_UNATTENDED_UPGRADES=false"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "apt-get install unattended-upgrades update-notifier-common powermgmt-base"
    dry_run "install verified configs/50unattended-upgrades + configs/20auto-upgrades"
    [[ -n "$ADMIN_EMAIL" ]] && dry_run "write /etc/apt/apt.conf.d/52unattended-upgrades-twdxos (Mail $ADMIN_EMAIL)"
    mark_step "unattended-upgrades" "dry-run"
else
    if { [[ "$OFFLINE" == "true" ]] || apt-get install -y -q unattended-upgrades update-notifier-common powermgmt-base; }; then
        fetch_verified "configs/50unattended-upgrades" /etc/apt/apt.conf.d/50unattended-upgrades
        fetch_verified "configs/20auto-upgrades"       /etc/apt/apt.conf.d/20auto-upgrades
        if [[ -n "$ADMIN_EMAIL" ]]; then
            cat > /etc/apt/apt.conf.d/52unattended-upgrades-twdxos <<EOF
// TWDxOSOptimisation — failure notifications (generated; ADMIN_EMAIL).
// Requires a working MTA or bsd-mailx to actually deliver.
Unattended-Upgrade::Mail "${ADMIN_EMAIL}";
Unattended-Upgrade::MailReport "on-change";
EOF
            chmod 644 /etc/apt/apt.conf.d/52unattended-upgrades-twdxos
        fi
        systemctl enable --now unattended-upgrades &>/dev/null || true
        mark_step "unattended-upgrades" "ok" "security-pocket only"
        success "unattended-upgrades active (security updates only)"
    else
        mark_step "unattended-upgrades" "failed" "package install failed"
    fi
fi

# ── 2. fail2ban ────────────────────────────────────────────────────────────
step "Intrusion prevention (fail2ban)"
if [[ "$ENABLE_FAIL2BAN" != "true" ]]; then
    mark_step "fail2ban" "skipped" "ENABLE_FAIL2BAN=false"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "apt-get install fail2ban; install verified configs/fail2ban-jail.local → /etc/fail2ban/jail.local"
    mark_step "fail2ban" "dry-run"
else
    if { [[ "$OFFLINE" == "true" ]] || apt-get install -y -q fail2ban; }; then
        fetch_verified "configs/fail2ban-jail.local" /etc/fail2ban/jail.local
        chmod 644 /etc/fail2ban/jail.local
        systemctl enable fail2ban &>/dev/null || true
        systemctl restart fail2ban || warn "fail2ban restart failed — check 'fail2ban-client -d'"
        mark_step "fail2ban" "ok"
        success "fail2ban active (ignoreip = loopback only — add trusted CIDRs in jail.local)"
    else
        mark_step "fail2ban" "failed" "package install failed"
    fi
fi

# ── 3. needrestart ────────────────────────────────────────────────────────
step "Service restart policy (needrestart)"
if [[ "$ENABLE_NEEDRESTART" != "true" ]]; then
    mark_step "needrestart" "skipped" "ENABLE_NEEDRESTART=false"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "apt-get install needrestart; install verified configs/needrestart.conf (list-only)"
    mark_step "needrestart" "dry-run"
else
    if { [[ "$OFFLINE" == "true" ]] || apt-get install -y -q needrestart; }; then
        fetch_verified "configs/needrestart.conf" /etc/needrestart/needrestart.conf
        mark_step "needrestart" "ok" "restart mode = list-only"
        success "needrestart configured (lists services needing restart; does not auto-restart)"
    else
        mark_step "needrestart" "failed" "package install failed"
    fi
fi

# ── 4. Kernel-reboot timer ────────────────────────────────────────────────
step "Conditional kernel-reboot timer"
if [[ "$ENABLE_AUTO_REBOOT" != "true" ]]; then
    mark_step "auto-reboot" "skipped" "ENABLE_AUTO_REBOOT=false"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "install auto-reboot.service + auto-reboot.timer (OnCalendar $REBOOT_TIME, only if /run/reboot-required)"
    mark_step "auto-reboot" "dry-run"
else
    svc=$(mktemp); tmr=$(mktemp); CLEANUP_FILES+=("$svc" "$tmr")
    fetch_verified "configs/auto-reboot.service"   "$svc"
    fetch_verified "configs/auto-reboot.timer.tpl" "$tmr"
    install -m 644 "$svc" /etc/systemd/system/auto-reboot.service
    sed "s|__REBOOT_TIME__|${REBOOT_TIME}|g" "$tmr" > /etc/systemd/system/auto-reboot.timer
    chmod 644 /etc/systemd/system/auto-reboot.timer
    systemctl daemon-reload
    systemctl enable --now auto-reboot.timer &>/dev/null || true
    rm -f "$svc" "$tmr"
    mark_step "auto-reboot" "ok" "nightly at $REBOOT_TIME"
    success "auto-reboot.timer scheduled ($REBOOT_TIME, 5-min grace, only when a reboot is pending)"
fi

# ── 5. Time synchronisation ───────────────────────────────────────────────
step "Time synchronisation"
if [[ "$ENABLE_TIMESYNC" != "true" ]]; then
    mark_step "timesync" "skipped" "ENABLE_TIMESYNC=false"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "timedatectl set-ntp true (or enable chrony if present)"
    mark_step "timesync" "dry-run"
else
    if command -v chronyd &>/dev/null || dpkg -s chrony &>/dev/null 2>&1; then
        systemctl enable --now chrony &>/dev/null || systemctl enable --now chronyd &>/dev/null || true
        mark_step "timesync" "ok" "chrony"
        success "chrony enabled for time sync"
    elif command -v timedatectl &>/dev/null; then
        timedatectl set-ntp true 2>/dev/null || true
        systemctl enable --now systemd-timesyncd &>/dev/null || true
        if timedatectl show -p NTP --value 2>/dev/null | grep -qi yes; then
            mark_step "timesync" "ok" "systemd-timesyncd"
            success "systemd-timesyncd enabled (NTP=yes)"
        else
            mark_step "timesync" "failed" "NTP not active after enable"
        fi
    else
        mark_step "timesync" "failed" "no timedatectl / chrony available"
    fi
fi

# ── 6. journald persistence + size caps ──────────────────────────────────
step "journald persistence & retention"
if [[ "$ENABLE_JOURNALD_TUNING" != "true" ]]; then
    mark_step "journald" "skipped" "ENABLE_JOURNALD_TUNING=false"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "install verified configs/journald-twdxos.conf → /etc/systemd/journald.conf.d/99-twdxos.conf"
    mark_step "journald" "dry-run"
else
    mkdir -p /etc/systemd/journald.conf.d
    fetch_verified "configs/journald-twdxos.conf" /etc/systemd/journald.conf.d/99-twdxos.conf
    systemctl restart systemd-journald || warn "journald restart failed"
    mark_step "journald" "ok"
    success "journald: persistent storage, capped size, 1-month retention"
fi

# ── 7. Weekly cleanup script ─────────────────────────────────────────────
if [[ "$ENABLE_CLEANUP" == "true" ]]; then
    step "Weekly cleanup script"
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run "write /usr/local/bin/vm-system-cleanup.sh"
        mark_step "cleanup-script" "dry-run"
    else
        cat > /usr/local/bin/vm-system-cleanup.sh <<'EOF'
#!/bin/bash
set -uo pipefail
LOG="/var/log/vm-system-cleanup.log"
{
    echo "=== $(date -Iseconds) system cleanup ==="
    apt-get autoremove --purge -y || true
    apt-get autoclean -y || true
    journalctl --vacuum-time=30d --vacuum-size=500M || true
    echo "=== done ==="
} >> "$LOG" 2>&1
EOF
        chmod 750 /usr/local/bin/vm-system-cleanup.sh
        [[ -f /var/log/vm-system-cleanup.log ]] || install -m 640 -o root -g adm /dev/null /var/log/vm-system-cleanup.log
        mark_step "cleanup-script" "ok"
        success "cleanup script generated"
    fi
fi

# ── 8. Log rotation ─────────────────────────────────────────────────────
step "Log rotation"
if [[ "$DRY_RUN" == "true" ]]; then
    dry_run "write /etc/logrotate.d/twdxos"
    mark_step "logrotate" "dry-run"
else
    {
        [[ "$WP_ENABLED" == "true" ]] && echo "$LOG_FILE"
        echo "/var/log/vm-system-cleanup.log {"
        echo "    weekly"
        echo "    rotate 8"
        echo "    compress"
        echo "    delaycompress"
        echo "    missingok"
        echo "    notifempty"
        echo "    create 0640 root adm"
        echo "}"
    } > /etc/logrotate.d/twdxos
    chmod 644 /etc/logrotate.d/twdxos
    mark_step "logrotate" "ok"
    success "log rotation configured"
fi

# ── 9. Optional WordPress module ───────────────────────────────────────
if [[ "$WP_ENABLED" == "true" ]]; then
    step "WP-CLI"
    WP_CLI_PINNED_SHA512="${WP_CLI_PINNED_SHA512:-}"   # set to the release digest to enforce it
    if command -v wp &>/dev/null; then
        info "WP-CLI already present — skipping download"
        mark_step "wp-cli" "skipped" "already installed"
    elif [[ "$DRY_RUN" == "true" ]]; then
        dry_run "download wp-cli.phar and verify (pinned SHA512 if set, else upstream .sha512 [TOFU])"
        mark_step "wp-cli" "dry-run"
    elif [[ "$OFFLINE" == "true" ]]; then
        if [[ -f "$BUNDLE_DIR/vendor/wp-cli.phar" ]]; then
            install -m 755 "$BUNDLE_DIR/vendor/wp-cli.phar" /usr/local/bin/wp
            mark_step "wp-cli" "ok" "from bundle"
        else
            warn "Offline: $BUNDLE_DIR/vendor/wp-cli.phar not found — install WP-CLI manually."
            mark_step "wp-cli" "failed" "missing in bundle"
        fi
    else
        tmp=$(mktemp); CLEANUP_FILES+=("$tmp")
        curl_fetch "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar" "$tmp" \
            || die "WP-CLI download failed." "$EX_ERR"
        actual=$(sha512sum "$tmp" | awk '{print $1}')
        if [[ -n "$WP_CLI_PINNED_SHA512" ]]; then
            [[ "$actual" == "$WP_CLI_PINNED_SHA512" ]] || die "WP-CLI SHA512 != pinned value." "$EX_INTEGRITY"
        else
            up_tmp=$(mktemp); CLEANUP_FILES+=("$up_tmp")
            curl_fetch "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512" "$up_tmp" \
                || die "Could not fetch upstream WP-CLI checksum." "$EX_ERR"
            up=$(awk '{print $1}' "$up_tmp"); rm -f "$up_tmp"
            [[ "$actual" == "$up" ]] || die "WP-CLI SHA512 mismatch vs upstream." "$EX_INTEGRITY"
            warn "WP-CLI verified against upstream .sha512 only (same channel — TOFU). Set WP_CLI_PINNED_SHA512 to harden."
        fi
        install -m 755 "$tmp" /usr/local/bin/wp
        rm -f "$tmp"
        mark_step "wp-cli" "ok"
        success "WP-CLI installed and verified"
    fi

    step "WordPress update script"
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run "render modules/wp-auto-update.sh.tpl → /usr/local/bin/wp-auto-update.sh"
        mark_step "wp-update-script" "dry-run"
    else
        tmp=$(mktemp); CLEANUP_FILES+=("$tmp")
        fetch_verified "modules/wp-auto-update.sh.tpl" "$tmp"
        sed -e "s|__WP_PATH__|${WP_PATH}|g" -e "s|__WP_USER__|${WP_USER}|g" -e "s|__LOG_FILE__|${LOG_FILE}|g" \
            "$tmp" > /usr/local/bin/wp-auto-update.sh
        chmod 750 /usr/local/bin/wp-auto-update.sh
        rm -f "$tmp"
        [[ -f "$LOG_FILE" ]] || install -m 640 -o root -g adm /dev/null "$LOG_FILE"
        mark_step "wp-update-script" "ok"
        success "wp-auto-update.sh installed"
    fi
fi

# ── 10. Cron jobs ─────────────────────────────────────────────────────
step "Schedules"
CRON_FILE="/etc/cron.d/twdxos"
CLEANUP_SCHEDULE=$(echo "$CRON_SCHEDULE" | sed 's/^[0-9*,/\-]*/30/')

if [[ "$WP_ENABLED" != "true" && "$ENABLE_CLEANUP" != "true" ]]; then
    [[ "$DRY_RUN" == "true" ]] || rm -f "$CRON_FILE"
    info "No WP module and no cleanup — no cron file needed"
    mark_step "cron" "skipped" "nothing to schedule"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "write $CRON_FILE (schedule '$CRON_SCHEDULE')"
    mark_step "cron" "dry-run"
else
    {
        echo "# TWDxOSOptimisation (linux-debian) — managed by install.sh; re-run to update."
        echo "SHELL=/bin/bash"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"
        if [[ -n "$ADMIN_EMAIL" ]]; then echo "MAILTO=$ADMIN_EMAIL"; else echo "MAILTO="; fi
        [[ "$WP_ENABLED" == "true" ]]   && echo "$CRON_SCHEDULE root /usr/local/bin/wp-auto-update.sh"
        [[ "$ENABLE_CLEANUP" == "true" ]] && echo "$CLEANUP_SCHEDULE root /usr/local/bin/vm-system-cleanup.sh"
    } > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    mark_step "cron" "ok" "$CRON_SCHEDULE"
    success "cron written to $CRON_FILE"
fi

# ── Summary ─────────────────────────────────────────────────────────────
if (( STEP_FAILURES > 0 )); then
    warn "Completed with $STEP_FAILURES failed step(s) — review the output above."
    [[ "$JSON_OUTPUT" == "true" ]] || _out "${BOLD}Result: PARTIAL${NC}"
    FINAL_EXIT="$EX_PARTIAL"
    emit_json "partial"
    exit "$EX_PARTIAL"
fi

if [[ "$JSON_OUTPUT" != "true" ]]; then
    wp_state="disabled"; [[ "$WP_ENABLED" == "true" ]] && wp_state="enabled"
    _out ""
    _out "${GREEN}${BOLD}  TWDxOSOptimisation ${TWDX_VERSION} installed on $(hostname 2>/dev/null || echo host)${NC}"
    _out "  WordPress module: ${wp_state}"
    _out ""
fi
FINAL_EXIT="$EX_OK"
emit_json "ok"
exit "$EX_OK"
