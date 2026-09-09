#!/bin/bash
# =============================================================================
# TWDxOSOptimisation — macOS Installer
# https://github.com/TheWebDexterTech/TWDxOSOptimisation
#
# Schedules declutter.sh (Homebrew / cache / log maintenance, optional macOS
# updates) via a per-user launchd LaunchAgent, and installs the optional
# WP-CLI module when WP_PATH is set.
#
# Enterprise flags:  --json  --offline  --non-interactive  --require-signatures
#                    --strict   Exit: 0 ok · 2 usage · 3 preflight · 4 partial · 5 integrity
#
# Usage (pinned one-liner — see README for the release tag):
#   curl -fsSL https://raw.githubusercontent.com/TheWebDexterTech/TWDxOSOptimisation/v2.0.0/platforms/macos/install.sh | sudo bash
#
# Tested: macOS 26 Tahoe, Sequoia, Sonoma — Apple Silicon + Intel
# License: MIT
# =============================================================================

set -euo pipefail

TWDX_VERSION="2.0.0"
TWDX_PLATFORM="macos"
TWDX_SCRIPT="install"

EX_OK=0; EX_ERR=1; EX_USAGE=2; EX_PREFLIGHT=3; EX_PARTIAL=4; EX_INTEGRITY=5

DRY_RUN="${DRY_RUN:-false}"
OFFLINE="${OFFLINE:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"
REQUIRE_SIGNATURES="${REQUIRE_SIGNATURES:-false}"

ENABLE_CLEANUP="${ENABLE_CLEANUP:-true}"
ENABLE_OS_UPDATES="${ENABLE_OS_UPDATES:-false}"
DECLUTTER_TIME="${DECLUTTER_TIME:-03:30:00}"
WP_PATH="${WP_PATH:-}"
LOG_FILE="${LOG_FILE:-}"

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
        "$STEP_FAILURES" "$FINAL_EXIT" "$(json_escape "$(hostname 2>/dev/null || echo host)")" \
        "$(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" "$joined"
}
# shellcheck disable=SC2317  # reached via 'trap ... EXIT'
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

die() {
    local code="${2:-$EX_ERR}"
    _out "${RED}[fail]${NC}  $1"
    FINAL_EXIT="$code"
    emit_json "error"
    exit "$code"
}
validate_bool() { [[ "$1" == "true" || "$1" == "false" ]] || die "$2 must be true/false (got '$1')" "$EX_USAGE"; }
validate_time() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$ ]] || die "$2 must be HH:MM:SS (got '$1')" "$EX_USAGE"; }
validate_wp_path() { [[ -z "$1" || "$1" =~ ^/[a-zA-Z0-9/_.\ \-]*$ ]] || die "WP_PATH '$1' unsafe." "$EX_USAGE"; }
validate_wp_user() { [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]{0,31}$ ]] || die "WP_USER '$1' invalid." "$EX_USAGE"; }

show_help() {
    cat <<'EOF'
TWDxOSOptimisation — macOS Installer

Usage: sudo bash install.sh [options]

Options: --dry-run/--check  --json  --offline  --non-interactive
         --require-signatures  --strict  --ref <git-ref>  --help

Environment:
  ENABLE_CLEANUP [true]  ENABLE_OS_UPDATES [false]  DECLUTTER_TIME [03:30:00]
  WP_PATH (unset = WP module OFF)  WP_USER [console user]  LOG_FILE
  OFFLINE / NON_INTERACTIVE / JSON_OUTPUT / REQUIRE_SIGNATURES /
  DRY_RUN / TWDX_REF / BUNDLE_DIR / CURL_OPTS

Run with sudo (not a plain root shell) so $SUDO_USER identifies the
LaunchAgent owner.
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
    echo "                 TWDxOSOptimisation — macOS Installer              "
    echo "                     v${TWDX_VERSION}  ·  TheWebDexter.com          "
    echo "  ================================================================="
    printf '%b\n' "${NC}"
}
[[ "$DRY_RUN" == "true" ]] && warn "Dry-run mode: no changes will be made."
[[ "$TWDX_REF" == "main" && "$OFFLINE" != "true" ]] && \
    warn "Unpinned ref 'main'. For production pin a release: --ref v2.0.0 (see README)."

declare -A FILE_CHECKSUMS=(
    ["declutter.sh"]="d3f136c43af992bc596d0a03fa9c66ef5f950c9ebaf2f84d4274fa2442f97c76"
    ["configs/com.twdxos.declutter.plist.tpl"]="5c54d16ba79e36b1687c58bb160b0407814b27655675c19f422b0829dd2c798f"
    ["modules/wp-auto-update.sh.tpl"]="bbbed2b48b8eed57bee25c6028a8eb7eb9621c7467655240b412f3137bb4304f"
)

PUBKEY_FILE="${BUNDLE_DIR:+$BUNDLE_DIR/}keys/twdxos-release.pub"
SIG_CAPABLE=false
if command -v minisign &>/dev/null && [[ -f "$PUBKEY_FILE" ]] && ! grep -q "REPLACE-WITH-REAL-PUBLIC-KEY" "$PUBKEY_FILE" 2>/dev/null; then
    SIG_CAPABLE=true
fi
[[ "$REQUIRE_SIGNATURES" == "true" && "$SIG_CAPABLE" != "true" ]] && \
    die "--require-signatures set but minisign / a real keys/twdxos-release.pub are unavailable." "$EX_INTEGRITY"

curl_fetch() {
    # shellcheck disable=SC2086
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
        --connect-timeout 15 --max-time 120 ${CURL_OPTS:-} "$1" -o "$2"
}
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

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
                warn "No signature for '$path' — SHA256 only."; sig=""
            fi
        fi
    fi
    local actual; actual=$(sha256_of "$tmp")
    [[ "$actual" == "$expected" ]] || die "Checksum mismatch for '$path' (want $expected got $actual)." "$EX_INTEGRITY"
    if [[ -n "$sig" && "$SIG_CAPABLE" == "true" ]]; then
        minisign -Vqm "$tmp" -x "$sig" -p "$PUBKEY_FILE" || die "Signature verification FAILED for '$path'." "$EX_INTEGRITY"
        info "signature OK: $path"
    fi
    install -m 644 "$tmp" "$dest"
    rm -f "$tmp"; [[ -n "$sig" && -f "$sig" ]] && rm -f "$sig"
    success "Verified & installed $(basename "$dest")"
}

step "Preflight"
[[ "$(uname -s)" != "Darwin" ]] && die "This installer targets macOS only." "$EX_PREFLIGHT"
[[ $EUID -ne 0 ]] && die "Run via: sudo bash install.sh" "$EX_PREFLIGHT"
[[ "$OFFLINE" == "true" && ! -f "$BUNDLE_DIR/declutter.sh" ]] && die "Offline: '$BUNDLE_DIR/declutter.sh' not found. Set BUNDLE_DIR." "$EX_PREFLIGHT"

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER=$(stat -f%Su /dev/console 2>/dev/null || echo "")
fi
[[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]] && die "Could not determine a non-root console user. Run 'sudo bash install.sh' as that user." "$EX_PREFLIGHT"
TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null) || die "User '$TARGET_USER' not found." "$EX_PREFLIGHT"
TARGET_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[[ -z "$TARGET_HOME" ]] && die "Could not resolve home dir for '$TARGET_USER'." "$EX_PREFLIGHT"
LOG_FILE="${LOG_FILE:-$TARGET_HOME/Library/Logs/macos-declutter/wp-auto-update.log}"
info "Target user: $TARGET_USER (uid $TARGET_UID, home $TARGET_HOME)"

step "Validating configuration"
for b in ENABLE_CLEANUP ENABLE_OS_UPDATES DRY_RUN OFFLINE NON_INTERACTIVE JSON_OUTPUT REQUIRE_SIGNATURES; do
    validate_bool "${!b}" "$b"
done
validate_time "$DECLUTTER_TIME" "DECLUTTER_TIME"
validate_wp_path "$WP_PATH"
WP_ENABLED=false
if [[ -n "$WP_PATH" ]]; then
    WP_ENABLED=true
    WP_USER="${WP_USER:-$TARGET_USER}"
    validate_wp_user "$WP_USER"
fi
success "Configuration valid"

DECLUTTER_HOUR=$(cut -d: -f1 <<< "$DECLUTTER_TIME")
DECLUTTER_MINUTE=$(cut -d: -f2 <<< "$DECLUTTER_TIME")
LAUNCH_AGENTS_DIR="$TARGET_HOME/Library/LaunchAgents"
DECLUTTER_PLIST="$LAUNCH_AGENTS_DIR/com.twdxos.declutter.plist"
DECLUTTER_BIN="/usr/local/bin/twdxos-declutter.sh"

# ── 1. declutter.sh ──────────────────────────────────────────────────────
step "Installing declutter.sh"
if [[ "$DRY_RUN" == "true" ]]; then
    dry_run "install verified declutter.sh → $DECLUTTER_BIN"
    mark_step "declutter-bin" "dry-run"
else
    mkdir -p /usr/local/bin
    fetch_verified "declutter.sh" "$DECLUTTER_BIN"
    chmod 755 "$DECLUTTER_BIN"
    mark_step "declutter-bin" "ok"
fi

# ── 2. LaunchAgent ──────────────────────────────────────────────────────
if [[ "$ENABLE_CLEANUP" == "true" ]]; then
    step "Scheduling declutter.sh (launchd)"
    EXTRA_ARG_ELEMENT=""
    [[ "$ENABLE_OS_UPDATES" == "true" ]] && EXTRA_ARG_ELEMENT="<string>--os-updates</string>"
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run "render plist → $DECLUTTER_PLIST; launchctl bootstrap gui/$TARGET_UID (weekly $DECLUTTER_TIME)"
        mark_step "launchagent" "dry-run"
    else
        mkdir -p "$LAUNCH_AGENTS_DIR"
        chown "$TARGET_USER" "$LAUNCH_AGENTS_DIR" 2>/dev/null || true
        tmp=$(mktemp); CLEANUP_FILES+=("$tmp")
        fetch_verified "configs/com.twdxos.declutter.plist.tpl" "$tmp"
        sed -e "s|__SCRIPT_PATH__|${DECLUTTER_BIN}|g" \
            -e "s|__WEEKDAY__|0|g" \
            -e "s|__HOUR__|${DECLUTTER_HOUR}|g" \
            -e "s|__MINUTE__|${DECLUTTER_MINUTE}|g" \
            -e "s|__EXTRA_ARG_ELEMENT__|${EXTRA_ARG_ELEMENT}|g" \
            "$tmp" > "$DECLUTTER_PLIST"
        chown "$TARGET_USER" "$DECLUTTER_PLIST"
        chmod 644 "$DECLUTTER_PLIST"
        rm -f "$tmp"
        launchctl bootout "gui/$TARGET_UID" "$DECLUTTER_PLIST" 2>/dev/null || true
        if launchctl bootstrap "gui/$TARGET_UID" "$DECLUTTER_PLIST" 2>/dev/null; then
            mark_step "launchagent" "ok" "weekly Sun $DECLUTTER_TIME"
            success "declutter.sh scheduled weekly (os-updates: $ENABLE_OS_UPDATES)"
        else
            mark_step "launchagent" "failed" "launchctl bootstrap failed (GUI session required)"
        fi
    fi
else
    mark_step "launchagent" "skipped" "ENABLE_CLEANUP=false"
fi

# ── 3. Optional WP module ───────────────────────────────────────────────
if [[ "$WP_ENABLED" == "true" ]]; then
    step "Optional WP-CLI module"
    if [[ "$DRY_RUN" == "true" ]]; then
        dry_run "ensure wp-cli (brew) for $TARGET_USER; render modules/wp-auto-update.sh.tpl → /usr/local/bin/wp-auto-update.sh"
        mark_step "wp-module" "dry-run"
    else
        if ! sudo -u "$TARGET_USER" bash -lc 'command -v wp' &>/dev/null; then
            [[ "$OFFLINE" == "true" ]] && warn "Offline: install wp-cli manually (brew install wp-cli)" \
                || sudo -u "$TARGET_USER" brew install wp-cli || warn "brew install wp-cli failed — install manually"
        fi
        tmp=$(mktemp); CLEANUP_FILES+=("$tmp")
        fetch_verified "modules/wp-auto-update.sh.tpl" "$tmp"
        sed -e "s|__WP_PATH__|${WP_PATH}|g" -e "s|__WP_USER__|${WP_USER}|g" -e "s|__LOG_FILE__|${LOG_FILE}|g" \
            "$tmp" > /usr/local/bin/wp-auto-update.sh
        chmod 755 /usr/local/bin/wp-auto-update.sh
        rm -f "$tmp"
        mkdir -p "$(dirname "$LOG_FILE")"; chown -R "$TARGET_USER" "$(dirname "$LOG_FILE")" 2>/dev/null || true
        mark_step "wp-module" "ok"
        success "wp-auto-update.sh installed (run manually or wrap in your own launchd job)"
    fi
else
    info "WP_PATH not set — WP-CLI module skipped (the common case on macOS)"
    mark_step "wp-module" "skipped" "WP_PATH unset"
fi

if (( STEP_FAILURES > 0 )); then
    warn "Completed with $STEP_FAILURES failed step(s)."
    FINAL_EXIT="$EX_PARTIAL"; emit_json "partial"; exit "$EX_PARTIAL"
fi
[[ "$JSON_OUTPUT" == "true" ]] || _out "\n${GREEN}${BOLD}  TWDxOSOptimisation ${TWDX_VERSION} installed for $TARGET_USER${NC}\n"
FINAL_EXIT="$EX_OK"; emit_json "ok"; exit "$EX_OK"
