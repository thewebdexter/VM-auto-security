#!/bin/bash
# =============================================================================
# TWDxOSOptimisation — Linux (RHEL/Fedora/CentOS) Host Hardening
# https://github.com/TheWebDexterTech/TWDxOSOptimisation
#
# Idempotent OS hardening: SSH drop-in, kernel/network sysctls, firewalld,
# optional /dev/shm + /tmp mount-option hardening, SELinux status report.
# Never changes SELinux mode or policy. Standalone — no install.sh dependency.
#
# Enterprise flags:  --json  --non-interactive  --strict  --dry-run
# Exit codes:  0 ok · 2 usage · 3 preflight · 4 partial
#
# Tested: Rocky 9, AlmaLinux 9, Fedora 40 — x86_64 + aarch64
# License: MIT
# =============================================================================

set -euo pipefail

TWDX_VERSION="2.0.0"
TWDX_PLATFORM="linux-rhel"
TWDX_SCRIPT="harden"

EX_OK=0; EX_ERR=1; EX_USAGE=2; EX_PREFLIGHT=3; EX_PARTIAL=4

DRY_RUN="${DRY_RUN:-false}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"
ASSUME_YES="${ASSUME_YES:-false}"
ALLOW_PASSWORD_LOCKOUT="${ALLOW_PASSWORD_LOCKOUT:-false}"

SSH_PORT="${SSH_PORT:-22}"
ENABLE_FIREWALLD="${ENABLE_FIREWALLD:-true}"
OPEN_HTTP="${OPEN_HTTP:-true}"
OPEN_HTTPS="${OPEN_HTTPS:-true}"
HARDEN_SSH="${HARDEN_SSH:-true}"
HARDEN_SYSCTL="${HARDEN_SYSCTL:-true}"
HARDEN_SHM="${HARDEN_SHM:-true}"
HARDEN_TMP="${HARDEN_TMP:-false}"
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
# shellcheck disable=SC2317  # reached via 'trap ... EXIT'
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
validate_bool() { [[ "$1" == "true" || "$1" == "false" ]] || die "$2 must be true/false (got '$1')" "$EX_USAGE"; }
validate_port() { { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); } || die "$2 must be 1-65535 (got '$1')" "$EX_USAGE"; }

show_help() {
    cat <<'EOF'
TWDxOSOptimisation — Linux (RHEL/Fedora/CentOS) Host Hardening

Usage: sudo bash harden.sh [--dry-run|--json|--non-interactive|--assume-yes|--strict|--help]

Environment:
  SSH_PORT [22]  ENABLE_FIREWALLD [true]  OPEN_HTTP [true]  OPEN_HTTPS [true]
  HARDEN_SSH/HARDEN_SYSCTL [true]  HARDEN_SHM [true]  HARDEN_TMP [false]
  HARDEN_TMP_NOEXEC [false]  ALLOW_PASSWORD_LOCKOUT [false]
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
    echo "  TWDxOSOptimisation — Linux (RHEL/Fedora/CentOS) Host Hardening     "
    echo "                     v${TWDX_VERSION}  ·  TheWebDexter.com          "
    echo "  ================================================================="
    printf '%b\n' "${NC}"
}
[[ "$DRY_RUN" == "true" ]] && warn "Dry-run mode: no changes will be made."

step "Validating configuration"
for b in DRY_RUN NON_INTERACTIVE JSON_OUTPUT ASSUME_YES ALLOW_PASSWORD_LOCKOUT \
         ENABLE_FIREWALLD OPEN_HTTP OPEN_HTTPS HARDEN_SSH HARDEN_SYSCTL HARDEN_SHM \
         HARDEN_TMP HARDEN_TMP_NOEXEC; do
    validate_bool "${!b}" "$b"
done
validate_port "$SSH_PORT" "SSH_PORT"
success "Configuration valid"

step "Preflight"
[[ $EUID -ne 0 ]] && die "Run as root (sudo)." "$EX_PREFLIGHT"
OS_ID="unknown"
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release; OS_ID="${ID:-unknown}"
fi
case "$OS_ID" in
    rhel|centos|rocky|almalinux|fedora) : ;;
    *) warn "Untested distro '$OS_ID' — proceeding" ;;
esac
if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
    info "SELinux Enforcing — this script never runs setenforce or edits policy."
fi

# ── 1. SSH hardening ─────────────────────────────────────────────────────
step "SSH daemon hardening"
SSH_DROPIN="/etc/ssh/sshd_config.d/99-twdxos-hardening.conf"
if [[ "$HARDEN_SSH" != "true" ]]; then
    mark_step "ssh" "skipped" "HARDEN_SSH=false"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "write $SSH_DROPIN, sshd -t, reload sshd"
    mark_step "ssh" "dry-run"
else
    key_found=false
    while IFS= read -r homedir; do
        [[ -n "$homedir" && -s "${homedir}/.ssh/authorized_keys" ]] && { key_found=true; break; }
    done < <(awk -F: '($3 >= 1000) || ($1 == "root") {print $6}' /etc/passwd)
    [[ -s /root/.ssh/authorized_keys ]] && key_found=true
    compgen -G "/etc/ssh/authorized_keys.d/*" >/dev/null 2>&1 && key_found=true
    if grep -RqiE '^\s*AuthorizedKeysCommand\s+\S' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null; then
        key_found=true
        info "AuthorizedKeysCommand present — key-based auth assumed provisioned externally."
    fi
    if [[ "$key_found" != "true" ]]; then
        warn "No SSH public key found for root or any regular user."
        if [[ "$ALLOW_PASSWORD_LOCKOUT" == "true" ]]; then
            warn "ALLOW_PASSWORD_LOCKOUT=true — proceeding."
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
        die "sshd config validation failed — drop-in removed." "$EX_ERR"
    fi
    rm -f /tmp/twdx-sshd-err
    systemctl reload sshd 2>/dev/null || warn "could not reload sshd"
    mark_step "ssh" "ok" "port $SSH_PORT"
    success "SSH hardened via $SSH_DROPIN"
fi

# ── 2. sysctl ───────────────────────────────────────────────────────────
step "Kernel & network hardening (sysctl)"
SYSCTL_CONF="/etc/sysctl.d/99-twdxos-hardening.conf"
if [[ "$HARDEN_SYSCTL" != "true" ]]; then
    mark_step "sysctl" "skipped" "HARDEN_SYSCTL=false"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "write $SYSCTL_CONF; sysctl --system"
    mark_step "sysctl" "dry-run"
else
    cat > "$SYSCTL_CONF" <<'EOF'
# TWDxOSOptimisation — kernel & network hardening (CIS RHEL 9 aligned).
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

net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.forwarding = 0

kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 2
kernel.sysrq = 0
kernel.kexec_load_disabled = 1
kernel.unprivileged_bpf_disabled = 1
kernel.perf_event_paranoid = 3
kernel.randomize_va_space = 2
net.core.bpf_jit_harden = 2

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
        mark_step "sysctl" "failed" "sysctl --system returned non-zero"
    fi
    if [[ "$(cat /proc/sys/kernel/kexec_load_disabled 2>/dev/null || echo 0)" == "1" ]] && systemctl is-enabled kdump >/dev/null 2>&1; then
        warn "kdump is enabled but kexec_load is now disabled — kdump fails on service restart (reboot loads it early). Adjust if you rely on crash dumps."
    fi
fi

# ── 3. /dev/shm and /tmp ───────────────────────────────────────────────
step "Mount-option hardening (/dev/shm, /tmp)"
harden_mount() {   # harden_mount <mountpoint> <opts>
    local mp="$1" opts="$2" cur
    cur=$(findmnt -no OPTIONS --target "$mp" 2>/dev/null || echo "")
    info "$mp current options: ${cur:-<unknown>}"
    [[ "$DRY_RUN" == "true" ]] && { dry_run "ensure $mp mounted $opts (fstab + remount)"; return 0; }
    sed -i '\| # twdxos-hardening$|d' /etc/fstab
    printf 'tmpfs %s tmpfs %s 0 0 # twdxos-hardening\n' "$mp" "$opts" >> /etc/fstab
    if mount -o "remount,$opts" "$mp" 2>/dev/null; then
        success "$mp remounted: $opts"
        return 0
    fi
    warn "$mp live remount failed — fstab updated; effective on next boot."
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
    mark_step "harden-tmp" "skipped" "HARDEN_TMP=false (/tmp noexec can break dnf scriptlets/installers)"
fi

# ── 4. firewalld ──────────────────────────────────────────────────────
step "firewalld"
if [[ "$ENABLE_FIREWALLD" != "true" ]]; then
    mark_step "firewalld" "skipped" "ENABLE_FIREWALLD=false"
elif [[ "$DRY_RUN" == "true" ]]; then
    dry_run "dnf install firewalld; enable --now; add-port $SSH_PORT/tcp; add http/https per flags; reload"
    [[ "$SSH_PORT" != "22" ]] && dry_run "remove-service=ssh from default zone (custom SSH port)"
    mark_step "firewalld" "dry-run"
else
    if command -v firewall-cmd &>/dev/null || dnf install -y -q firewalld; then
        systemctl enable --now firewalld
        firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null
        if [[ "$SSH_PORT" != "22" ]]; then
            firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1 || true
            warn "Custom SSH port $SSH_PORT: removed the stock 'ssh' service (port 22) from the default zone."
        fi
        [[ "$OPEN_HTTP"  == "true" ]] && firewall-cmd --permanent --add-service=http  >/dev/null
        [[ "$OPEN_HTTPS" == "true" ]] && firewall-cmd --permanent --add-service=https >/dev/null
        firewall-cmd --reload >/dev/null
        mark_step "firewalld" "ok" "ssh:$SSH_PORT http:$OPEN_HTTP https:$OPEN_HTTPS"
        success "firewalld configured (default zone denies everything else)"
        warn "Cloudflare-Tunnel users: once the tunnel works, remove-port ${SSH_PORT}/tcp and drop the cloud SG rule."
    else
        mark_step "firewalld" "failed" "could not install firewalld"
    fi
fi

# ── 5. SELinux status (report only) ─────────────────────────────────
step "SELinux status"
if command -v getenforce &>/dev/null; then
    mode=$(getenforce)
    case "$mode" in
        Enforcing)  success "SELinux: Enforcing"; mark_step "selinux" "ok" "Enforcing" ;;
        Permissive) warn "SELinux: Permissive — set SELINUX=enforcing in /etc/selinux/config and reboot."; mark_step "selinux" "failed" "Permissive" ;;
        Disabled)   warn "SELinux: Disabled — re-enable in /etc/selinux/config, relabel (touch /.autorelabel) and reboot."; mark_step "selinux" "failed" "Disabled" ;;
        *)          mark_step "selinux" "skipped" "unknown mode '$mode'" ;;
    esac
else
    warn "getenforce not found — SELinux tooling absent."
    mark_step "selinux" "skipped" "not installed"
fi

if (( STEP_FAILURES > 0 )); then
    warn "Hardening completed with $STEP_FAILURES issue(s) — review above."
    FINAL_EXIT="$EX_PARTIAL"; emit_json "partial"; exit "$EX_PARTIAL"
fi
[[ "$JSON_OUTPUT" == "true" ]] || _out "\n${GREEN}${BOLD}  Hardening complete on $(hostname 2>/dev/null || echo host)${NC}\n"
FINAL_EXIT="$EX_OK"; emit_json "ok"; exit "$EX_OK"
