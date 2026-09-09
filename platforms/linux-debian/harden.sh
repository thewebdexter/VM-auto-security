#!/bin/bash
# =============================================================================
# TWDxOSOptimisation — Linux (Debian/Ubuntu) Host Hardening
# https://github.com/TheWebDexterTech/TWDxOSOptimisation
#
# Idempotent OS hardening: SSH daemon drop-in, kernel/network sysctls, UFW,
# optional /dev/shm + /tmp mount-option hardening, and an AppArmor status
# check. Safe to re-run. Standalone — no dependency on install.sh.
#
# Enterprise flags:  --json  --non-interactive  --strict  --dry-run
# Exit codes:  0 ok · 2 usage · 3 preflight · 4 partial
#
# Usage:
#   sudo bash harden.sh [options]
#   sudo SSH_PORT=2222 NON_INTERACTIVE=true bash harden.sh
#
# Tested: Ubuntu 24.04 LTS / Debian 12 — aarch64 + x86_64
# License: MIT
# =============================================================================

set -euo pipefail

TWDX_VERSION="2.0.0"
TWDX_PLATFORM="linux-debian"
TWDX_SCRIPT="harden"

EX_OK=0; EX_ERR=1; EX_USAGE=2; EX_PREFLIGHT=3; EX_PARTIAL=4

DRY_RUN="${DRY_RUN:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"
ASSUME_YES="${ASSUME_YES:-false}"
ALLOW_PASSWORD_LOCKOUT="${ALLOW_PASSWORD_LOCKOUT:-false}"

SSH_PORT="${SSH_PORT:-22}"
ENABLE_UFW="${ENABLE_UFW:-true}"
OPEN_HTTP="${OPEN_HTTP:-true}"
OPEN_HTTPS="${OPEN_HTTPS:-true}"
HARDEN_SSH="${HARDEN_SSH:-true}"
HARDEN_SYSCTL="${HARDEN_SYSCTL:-true}"
HARDEN_SHM="${HARDEN_SHM:-true}"      # /dev/shm nodev,nosuid,noexec  (low risk)
HARDEN_TMP="${HARDEN_TMP:-false}"     # /tmp    nodev,nosuid[,noexec] (opt-in)
HARDEN_TMP_NOEXEC="${HARDEN_TMP_NOEXEC:-false}"

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
        "$(json_escape "$(hostname 2>/dev/null || echo "${HOSTNAME:-unknown}")")" "$(date -Iseconds)" "$joined"
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

die() { local code="${2:-$EX_ERR}"; _out "${RED}[fail]${NC}  $1"; FINAL_EXIT="$code"; emit_json "error"; exit "$code"; }
validate_bool() { [[ "$1" == "true" || "$1" == "false" ]] || die "$2 must be 'true' or 'false' (got: '$1')" "$EX_USAGE"; }
validate_port() {
    { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); } || die "$2 must be 1-65535 (got: '$1')" "$EX_USAGE"
}

show_help() {
    cat <<'EOF'
TWDxOSOptimisation — Linux (Debian/Ubuntu) Host Hardening

Usage: sudo bash harden.sh [options]

Options:
  --dry-run, --check     Preview only
  --json                 JSON result on stdout
  --non-interactive      Never prompt; fail closed on lockout risk
  --assume-yes           Auto-accept optional prompts
  --strict               = --non-interactive
  --help, -h

Environment:
  SSH_PORT [22]  ENABLE_UFW [true]  OPEN_HTTP [true]  OPEN_HTTPS [true]
  HARDEN_SSH [true]  HARDEN_SYSCTL [true]
  HARDEN_SHM [true]         /dev/shm -> nodev,nosuid,noexec
  HARDEN_TMP [false]        /tmp     -> nodev,nosuid
  HARDEN_TMP_NOEXEC [false] add noexec to /tmp (can break apt hooks / installers)
  ALLOW_PASSWORD_LOCKOUT [false]  proceed even with no SSH key present
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)             show_help; exit 0 ;;
        --dry-run|--check)      DRY_RUN="true" ;;
        --json)                JSON_OUTPUT="true" ;;
        --non-interactive)     NON_INTERACTIVE="true" ;;
        --assume-yes|--yes|-y) ASSUME_YES="true" ;;
        --strict)              NON_INTERACTIVE="true" ;;
        *)                     die "Unknown argument: $1 (use --help)" "$EX_USAGE" ;;
    esac
    shift
done
if [[ "$JSON_OUTPUT" == "true" || ! -t 1 ]]; then RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; CYAN=""; NC=""; fi

[[ "$JSON_OUTPUT" == "true" ]] || {
    printf '%b\n' "${CYAN}${BOLD}"
    echo "  ================================================================="
    echo "     TWDxOSOptimisation — Linux (Debian/Ubuntu) Host Hardening      "
    echo "                     v${TWDX_VERSION}  ·  TheWebDexter.com          "
    echo "  ================================================================="
    printf '%b\n' "${NC}"
}
[[ "$DRY_RUN" == "true" ]] && warn "Dry-run mode: no changes will be made."

step "Validating configuration"
for b in DRY_RUN NON_INTERACTIVE JSON_OUTPUT ASSUME_YES ALLOW_PASSWORD_LOCKOUT \
         ENABLE_UFW OPEN_HTTP OPEN_HTTPS HARDEN_SSH HARDEN_SYSCTL HARDEN_SHM \
         HARDEN_TMP HARDEN_TMP_NOEXEC; do
    validate_bool "${!b}" "$b"
done
validate_port "$SSH_PORT" "SSH_PORT"
success "Configuration valid"

step "Preflight"
[[ $EUID -ne 0 ]] && die "Run as root (sudo)." "$EX_PREFLIGHT"
OS=$(lsb_release -si 2>/dev/null || echo "Unknown")
[[ "$OS" =~ ^(Ubuntu|Debian)$ ]] || warn "Tested on Ubuntu/Debian — proceeding anyway on $OS"

# ── 1. SSH daemon hardening ────────────────────────────────────────────────
step "SSH daemon hardening"
SSH_DROPIN="/etc/ssh/sshd_config.d/99-twdxos-hardening.conf"
if [[ "$HARDEN_SSH" != "true" ]]; then
    mark_step "ssh" "skipped" "HARDEN_SSH=false"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "write $SSH_DROPIN, validate with sshd -t, reload ssh"
    mark_step "ssh" "dry-run"
else
    # Lockout guard: look for ANY viable key-based auth path before we turn
    # password auth off.
    key_found=false
    while IFS= read -r homedir; do
        [[ -n "$homedir" && -s "${homedir}/.ssh/authorized_keys" ]] && { key_found=true; break; }
    done < <(awk -F: '($3 >= 1000) || ($1 == "root") {print $6}' /etc/passwd)
    [[ -s /root/.ssh/authorized_keys ]] && key_found=true
    compgen -G "/etc/ssh/authorized_keys.d/*" >/dev/null 2>&1 && key_found=true
    if grep -RqiE '^\s*AuthorizedKeysCommand\s+\S' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null; then
        key_found=true
        info "AuthorizedKeysCommand present — assuming key-based auth is provisioned externally."
    fi

    if [[ "$key_found" != "true" ]]; then
        warn "No SSH public key found for root or any regular user."
        warn "Disabling PasswordAuthentication now would lock you out."
        if [[ "$ALLOW_PASSWORD_LOCKOUT" == "true" ]]; then
            warn "ALLOW_PASSWORD_LOCKOUT=true — proceeding anyway."
        elif [[ "$NON_INTERACTIVE" == "true" || ! -c /dev/tty ]]; then
            die "Refusing to disable password auth with no key present. Set ALLOW_PASSWORD_LOCKOUT=true to override." "$EX_PREFLIGHT"
        else
            read -r -p "  Type 'lockout' to proceed anyway: " ans < /dev/tty || ans=""
            [[ "$ans" == "lockout" ]] || die "Aborted by operator." "$EX_PREFLIGHT"
        fi
    fi

    mkdir -p /etc/ssh/sshd_config.d
    tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
# TWDxOSOptimisation — SSH hardening (CIS-aligned). First match wins.
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
HostbasedAuthentication no
IgnoreRhosts yes
PubkeyAuthentication yes
PermitUserEnvironment no
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30
AllowStreamLocalForwarding no
PermitTunnel no
GatewayPorts no

ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PrintLastLog yes
LogLevel VERBOSE

KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256,rsa-sha2-512-cert-v01@openssh.com,rsa-sha2-256-cert-v01@openssh.com
EOF
    if [[ "$SSH_PORT" != "22" ]]; then echo "Port $SSH_PORT" >> "$tmp"; fi
    install -m 644 "$tmp" "$SSH_DROPIN"
    rm -f "$tmp"

    if ! sshd -t 2>/tmp/twdx-sshd-err; then
        cat /tmp/twdx-sshd-err >&2
        rm -f "$SSH_DROPIN" /tmp/twdx-sshd-err
        die "sshd config validation failed — drop-in removed, no changes left behind." "$EX_ERR"
    fi
    rm -f /tmp/twdx-sshd-err
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || warn "could not reload ssh"
    mark_step "ssh" "ok" "port $SSH_PORT"
    success "SSH hardened via $SSH_DROPIN"
fi

# ── 2. Kernel & network sysctls ───────────────────────────────────────────
step "Kernel & network hardening (sysctl)"
SYSCTL_CONF="/etc/sysctl.d/99-twdxos-hardening.conf"
if [[ "$HARDEN_SYSCTL" != "true" ]]; then
    mark_step "sysctl" "skipped" "HARDEN_SYSCTL=false"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "write $SYSCTL_CONF; apply via sysctl --system"
    mark_step "sysctl" "dry-run"
else
    cat > "$SYSCTL_CONF" <<'EOF'
# TWDxOSOptimisation — kernel & network hardening (CIS Ubuntu/Debian aligned).

# IPv4
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.ip_forward = 0

# IPv6 (NOT disabled — only hardened)
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.forwarding = 0

# Kernel
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 2
kernel.sysrq = 0
kernel.kexec_load_disabled = 1
kernel.unprivileged_bpf_disabled = 1
kernel.perf_event_paranoid = 3
kernel.randomize_va_space = 2
net.core.bpf_jit_harden = 2

# Filesystem (TOCTOU hardening)
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
EOF
    chmod 644 "$SYSCTL_CONF"
    if sysctl --system >/dev/null 2>&1; then
        mark_step "sysctl" "ok"
        success "sysctl hardening applied ($SYSCTL_CONF)"
    else
        mark_step "sysctl" "failed" "sysctl --system returned non-zero (some keys may be unavailable on this kernel)"
    fi
    if [[ "$(cat /proc/sys/kernel/kexec_load_disabled 2>/dev/null || echo 0)" == "1" ]] && systemctl is-enabled kdump >/dev/null 2>&1; then
        warn "kdump is enabled but kexec_load is now disabled — kdump will fail on service restart. Reboot loads it early; adjust if you rely on crash dumps."
    fi
fi

# ── 3. /dev/shm and /tmp mount options ────────────────────────────────────
step "Mount-option hardening (/dev/shm, /tmp)"
harden_mount() {   # harden_mount <mountpoint> <opts>
    local mp="$1" opts="$2" cur
    cur=$(findmnt -no OPTIONS --target "$mp" 2>/dev/null || echo "")
    info "$mp current options: ${cur:-<unknown>}"
    [[ "$DRY_RUN" == "true" ]] && { dry_run "ensure $mp mounted $opts (fstab + remount)"; return 0; }
    # Remove any prior twdxos-managed line, then append a fresh one.
    sed -i '\| # twdxos-hardening$|d' /etc/fstab
    printf 'tmpfs %s tmpfs %s 0 0 # twdxos-hardening\n' "$mp" "$opts" >> /etc/fstab
    if mount -o "remount,$opts" "$mp" 2>/dev/null; then
        success "$mp remounted: $opts"
        return 0
    fi
    warn "$mp live remount failed — fstab updated; new options take effect on next boot."
    return 0
}
if [[ "$HARDEN_SHM" == "true" ]]; then
    harden_mount /dev/shm "defaults,nodev,nosuid,noexec"
    mark_step "harden-shm" "ok"
else
    mark_step "harden-shm" "skipped" "HARDEN_SHM=false"
fi
if [[ "$HARDEN_TMP" == "true" ]]; then
    tmp_opts="defaults,nodev,nosuid"
    if [[ "$HARDEN_TMP_NOEXEC" == "true" ]]; then tmp_opts="$tmp_opts,noexec"; fi
    harden_mount /tmp "$tmp_opts"
    mark_step "harden-tmp" "ok" "$tmp_opts"
else
    mark_step "harden-tmp" "skipped" "HARDEN_TMP=false (enable deliberately: /tmp noexec can break apt hooks/installers)"
fi

# ── 4. UFW firewall ──────────────────────────────────────────────────────
step "UFW firewall"
if [[ "$ENABLE_UFW" != "true" ]]; then
    mark_step "ufw" "skipped" "ENABLE_UFW=false"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "apt-get install ufw; allow $SSH_PORT/tcp $( [[ $OPEN_HTTP == true ]] && echo 80) $( [[ $OPEN_HTTPS == true ]] && echo 443); default deny incoming; enable"
    mark_step "ufw" "dry-run"
else
    if command -v ufw &>/dev/null || apt-get install -y -q ufw; then
        sed -i 's|^IPV6=.*|IPV6=yes|' /etc/default/ufw
        ufw allow "${SSH_PORT}/tcp" >/dev/null
        [[ "$OPEN_HTTP"  == "true" ]] && ufw allow 80/tcp  >/dev/null
        [[ "$OPEN_HTTPS" == "true" ]] && ufw allow 443/tcp >/dev/null
        ufw default deny incoming  >/dev/null
        ufw default allow outgoing >/dev/null
        ufw logging low >/dev/null
        ufw --force enable >/dev/null
        mark_step "ufw" "ok" "ssh:$SSH_PORT http:$OPEN_HTTP https:$OPEN_HTTPS"
        success "UFW enabled (default deny inbound)"
        warn "Cloudflare-Tunnel users: once the tunnel works, 'ufw delete allow ${SSH_PORT}/tcp' and drop the cloud SG rule."
    else
        mark_step "ufw" "failed" "could not install ufw"
    fi
fi

# ── 5. AppArmor status (report only) ─────────────────────────────────────
step "AppArmor status"
if command -v aa-status &>/dev/null; then
    if aa-status --enabled 2>/dev/null; then
        success "AppArmor is enabled ($(aa-status --profiled 2>/dev/null || echo '?') profiles loaded)"
        mark_step "apparmor" "ok"
    else
        warn "AppArmor is installed but NOT enabled — enable it in GRUB (apparmor=1 security=apparmor) and reboot."
        mark_step "apparmor" "failed" "installed but not enabled"
    fi
else
    warn "AppArmor tooling not installed — consider 'apt-get install apparmor apparmor-utils'."
    mark_step "apparmor" "skipped" "not installed"
fi

# ── Summary ────────────────────────────────────────────────────────────
if (( STEP_FAILURES > 0 )); then
    warn "Hardening completed with $STEP_FAILURES issue(s) — review above."
    FINAL_EXIT="$EX_PARTIAL"; emit_json "partial"; exit "$EX_PARTIAL"
fi
[[ "$JSON_OUTPUT" == "true" ]] || _out "\n${GREEN}${BOLD}  Hardening complete on $(hostname 2>/dev/null || echo host)${NC}\n"
FINAL_EXIT="$EX_OK"; emit_json "ok"; exit "$EX_OK"
