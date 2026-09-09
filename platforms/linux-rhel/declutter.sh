#!/usr/bin/env bash
#
# declutter.sh (RHEL/Fedora/CentOS)
#
# Goal: Help move a dnf-based Linux system closer to a "factory default"
# state by identifying (and optionally removing) unused packages, services,
# and leftover files — without breaking the system.
#
# Default mode: REPORT ONLY (dry-run). Nothing is changed unless --apply is given.
#
# Optimized for: Rocky Linux 9 / AlmaLinux 9 / RHEL 9 / Fedora 40 (x86_64, aarch64)
#
# Usage:
#   sudo ./declutter.sh            # report only, no changes
#   sudo ./declutter.sh --apply    # actually perform safe cleanup steps
#   sudo ./declutter.sh --apply --aggressive   # also offers to remove
#                                               # unused-but-installed packages
#                                               # (asks for confirmation each time)
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Globals / flags
# ---------------------------------------------------------------------------
APPLY=0
AGGRESSIVE=0
CRON=0
SILENT=0  # set by --cron; suppresses report text, only logs actual actions
JSON=0
LOG_DIR="/var/log/rhel-declutter"
LOG_FILE="$LOG_DIR/rhel-declutter-$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/var/run/rhel-declutter.lock"
ACTIONS_TAKEN=0

# Services that must NEVER be touched by the aggressive auto-disable step,
# regardless of how they look in the "enabled but inactive" list.
PROTECTED_SERVICES_REGEX='^(sshd|systemd-|NetworkManager|firewalld|dnf-automatic|crond|auditd|chronyd|dbus|udev|getty@|serial-getty@|polkit|rsyslog|selinux)'

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --aggressive) AGGRESSIVE=1 ;;
    --cron)
      APPLY=1
      CRON=1
      SILENT=1
      ;;
    --json)
      JSON=1
      SILENT=1
      ;;
    -h|--help)
      echo "Usage: $0 [--apply] [--aggressive] [--cron] [--json]"
      echo "  --apply       Actually perform safe actions (default: dry-run/report only)"
      echo "  --aggressive  In addition, interactively offer to purge unused-but-installed"
      echo "                packages and disable inactive services (asks before each one)."
      echo "                IGNORED if --cron is also set (no interactive prompts in cron)."
      echo "  --cron        Non-interactive mode for scheduled runs. Implies --apply,"
      echo "                auto-confirms safe steps (update/autoremove/clean),"
      echo "                skips all interactive --aggressive prompts, and refuses to"
      echo "                disable/remove anything matching the protected-services list."
      exit 0
      ;;
  esac
done

mkdir -p "$LOG_DIR"
# Reports contain a host inventory (listening ports, package/service lists).
chmod 750 "$LOG_DIR" 2>/dev/null || true
umask 027

# Prevent overlapping runs (important for cron)
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "Another instance of $0 is already running (lock: $LOCK_FILE). Exiting." >&2
  exit 1
fi
{ touch "$LOG_FILE" && chmod 640 "$LOG_FILE"; } 2>/dev/null || true
if [[ $JSON -eq 1 ]]; then exec 3>&1 1>>"$LOG_FILE" 2>&1; fi

# Trim old logs from this script so they don't become clutter themselves
find "$LOG_DIR" -type f -name 'rhel-declutter-*.log' -mtime +90 -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  if [[ $SILENT -eq 1 ]]; then
    echo -e "$@" >> "$LOG_FILE"
  else
    echo -e "$@" | tee -a "$LOG_FILE"
  fi
}

# action_log: always visible even in silent/cron mode — records actual changes
action_log() {
  echo -e "[ACTION] $*" | tee -a "$LOG_FILE"
}

note_action() {
  ACTIONS_TAKEN=$((ACTIONS_TAKEN + 1))
  action_log "$*"
}

section() {
  if [[ $SILENT -eq 0 ]]; then
    log "\n========================================================"
    log "  $1"
    log "========================================================"
  else
    log "\n--- $1 ---"
  fi
}

confirm() {
  local prompt="$1"
  if [[ $CRON -eq 1 ]]; then
    if [[ "${CONFIRM_SAFE:-0}" -eq 1 ]]; then
      log "$prompt -> auto-yes"
      return 0
    else
      log "$prompt -> skipped (interactive, not run in cron)"
      return 1
    fi
  fi
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
  fi
}

require_root

log "Log file: $LOG_FILE"
log "Mode: $([[ $APPLY -eq 1 ]] && echo APPLY || echo "DRY-RUN report only")"
[[ $AGGRESSIVE -eq 1 ]] && log "Aggressive mode: ON (interactive prompts for risky removals)"

# ---------------------------------------------------------------------------
# 1. OS Detection
# ---------------------------------------------------------------------------
section "1. OS Detection"

OS_ID=""
OS_VERSION=""
ARCH=$(uname -m)

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
fi

log "Detected OS: ${PRETTY_NAME:-unknown}"
log "ID: $OS_ID  VERSION: $OS_VERSION  ARCH: $ARCH"

if ! command -v dnf &>/dev/null; then
  log "dnf not found on this system — this script targets the RHEL/Fedora family."
  log "Package-manager steps below will be skipped."
fi

# ---------------------------------------------------------------------------
# 2. Update / Autoremove / Clean (dnf)
# ---------------------------------------------------------------------------
section "2. Package updates, autoremove, cache cleanup"

if command -v dnf &>/dev/null; then
  log "-- dnf check-update --"
  if [[ $APPLY -eq 1 ]]; then
    UPDATE_OK=0
    for attempt in 1 2 3; do
      # check-update exits 100 when updates are available — not a failure.
      dnf check-update | tee -a "$LOG_FILE"; rc=$?
      if [[ $rc -eq 0 || $rc -eq 100 ]]; then
        UPDATE_OK=1
        break
      fi
      log "dnf check-update failed (attempt $attempt/3), retrying in 15s..."
      sleep 15
    done
    if [[ $UPDATE_OK -eq 0 ]]; then
      log "dnf check-update failed after 3 attempts. Aborting upgrade/autoremove steps for this run."
    fi
  else
    log "(dry-run) would run: dnf check-update"
    UPDATE_OK=1
  fi

  log "\n-- dnf upgrade (applies all available updates, handles kernel/deps properly) --"
  if [[ $APPLY -eq 1 && $UPDATE_OK -eq 1 ]]; then
    if CONFIRM_SAFE=1 confirm "Proceed with 'dnf upgrade -y'?"; then
      dnf upgrade -y >> "$LOG_FILE" 2>&1
      note_action "dnf upgrade completed"
    fi
  elif [[ $APPLY -eq 1 ]]; then
    log "Skipping upgrade because dnf check-update failed."
  else
    log "(dry-run) would run: dnf upgrade -y"
  fi

  log "\n-- Packages that would be removed by autoremove --"
  dnf autoremove --assumeno 2>/dev/null | tee -a "$LOG_FILE"

  if [[ $APPLY -eq 1 ]]; then
    if CONFIRM_SAFE=1 confirm "Proceed with 'dnf autoremove -y'?"; then
      dnf autoremove -y >> "$LOG_FILE" 2>&1
      note_action "dnf autoremove completed"
    fi
  else
    log "(dry-run) would run: dnf autoremove -y"
  fi

  if [[ $APPLY -eq 1 ]]; then
    dnf clean all >> "$LOG_FILE" 2>&1
    note_action "dnf cache cleaned"
  else
    log "(dry-run) would run: dnf clean all"
  fi

  # Reboot check (RHEL family has no /var/run/reboot-required flag file;
  # `dnf needs-restarting -r` is the equivalent signal). It ships in
  # dnf-utils/yum-utils; probe the subcommand itself rather than a
  # non-existent "dnf-utils" binary.
  if dnf needs-restarting --help >/dev/null 2>&1; then
    # exit 1 = reboot required, 0 = not, 2+ = error
    dnf needs-restarting -r >/dev/null 2>&1; nr_rc=$?
    if [[ $nr_rc -eq 1 ]]; then
      note_action "REBOOT REQUIRED after package updates (dnf needs-restarting -r)."
      log "*** REBOOT REQUIRED — schedule one soon to apply kernel/library updates ***"
    fi
  else
    log "'dnf needs-restarting' unavailable — install dnf-utils to enable the reboot check."
  fi
else
  log "Skipping dnf-specific update/upgrade/autoremove (dnf not found)."
fi

# ---------------------------------------------------------------------------
# 3. Generic garbage collection (logs, tmp, old kernels, caches)
# ---------------------------------------------------------------------------
section "3. Garbage collection: old kernels, logs, tmp files, journal"

# --- Old kernels (dnf/rpm only) ---
if command -v dnf &>/dev/null; then
  CURRENT_KERNEL=$(uname -r)
  log "Current running kernel: $CURRENT_KERNEL"
  log "\n-- Installed kernel packages (current one is kept regardless) --"
  rpm -q kernel kernel-core kernel-modules 2>/dev/null | tee -a "$LOG_FILE"

  # installonly_limit in dnf.conf already caps old-kernel retention (default 3);
  # dnf itself prunes old kernels during upgrade, so no separate purge step here.
  KERNEL_COUNT=$(rpm -q kernel 2>/dev/null | wc -l)
  log "\nKernel packages currently installed: $KERNEL_COUNT (dnf's installonly_limit governs retention)"

  if [[ $APPLY -eq 1 && $AGGRESSIVE -eq 1 && $KERNEL_COUNT -gt 2 ]]; then
    if confirm "Run 'dnf remove --oldinstallonly' to prune old kernels beyond the retention limit?"; then
      dnf remove --oldinstallonly -y >> "$LOG_FILE" 2>&1 || true
      note_action "Pruned old kernel packages beyond installonly_limit"
    fi
  fi
fi

# --- journal logs ---
log "\n-- systemd journal disk usage --"
if command -v journalctl &>/dev/null; then
  journalctl --disk-usage >> "$LOG_FILE" 2>&1
  if [[ $APPLY -eq 1 ]]; then
    journalctl --vacuum-time=2weeks >> "$LOG_FILE" 2>&1
    note_action "Vacuumed systemd journal (kept last 2 weeks)"
  else
    log "(dry-run) would run: journalctl --vacuum-time=2weeks"
  fi
fi

# --- /var/log rotated/compressed leftovers ---
log "\n-- Large/old files under /var/log --"
find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.old" \) -printf '%p\t%k KB\n' 2>/dev/null \
  | sort -k2 -nr | head -n 20 | tee -a "$LOG_FILE"

if [[ $APPLY -eq 1 ]]; then
  DELETED_LOGS=$(find /var/log -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.old" \) -mtime +30 -print -delete 2>/dev/null | wc -l)
  [[ "$DELETED_LOGS" -gt 0 ]] && note_action "Removed $DELETED_LOGS rotated log files older than 30 days"
else
  log "(dry-run) would remove rotated log files older than 30 days."
fi

# Safe temp cleanup: regular files / symlinks only, same filesystem, never
# sockets/FIFOs/dirs, never system runtime paths. systemd-tmpfiles is
# preferred where present.
TMP_PRUNE=( -name 'systemd-private-*' -o -name '.X11-unix' -o -name '.XIM-unix'
            -o -name '.ICE-unix' -o -name '.font-unix' -o -name '.Test-unix'
            -o -name 'ssh-*' -o -name 'gpg-*' -o -name 'dbus-*'
            -o -name 'tmux-*' -o -name '.X0-lock' -o -name 'vmware-*' )

log "\n-- Stale regular files in /tmp and /var/tmp (older than 10 days) --"
find /tmp /var/tmp -xdev -mindepth 1 \( "${TMP_PRUNE[@]}" \) -prune -o \
     \( -type f -o -type l \) -mtime +10 -print 2>/dev/null | tee -a "$LOG_FILE"

if [[ $APPLY -eq 1 ]]; then
  if command -v systemd-tmpfiles &>/dev/null; then
    systemd-tmpfiles --clean >> "$LOG_FILE" 2>&1 || true
    note_action "Ran systemd-tmpfiles --clean"
  fi
  DELETED_TMP=$(find /tmp /var/tmp -xdev -mindepth 1 \( "${TMP_PRUNE[@]}" \) -prune -o \
                \( -type f -o -type l \) -mtime +10 -print -delete 2>/dev/null | wc -l)
  [[ "$DELETED_TMP" -gt 0 ]] && note_action "Cleared $DELETED_TMP stale temp files (>10 days, regular files/symlinks only)"
else
  log "(dry-run) would run systemd-tmpfiles --clean and remove the stale regular files listed above."
fi

# ---------------------------------------------------------------------------
# 4. Services audit: enabled but inactive / never used
# ---------------------------------------------------------------------------
section "4. systemd services: enabled vs active, candidates for review"

if command -v systemctl &>/dev/null; then
  log "-- Enabled services that are currently INACTIVE --"
  log "(These start at boot but aren't running now — review before disabling)"
  comm -23 \
    <(systemctl list-unit-files --type=service --state=enabled --no-legend | awk '{print $1}' | sort) \
    <(systemctl list-units --type=service --state=running --no-legend | awk '{print $1}' | sort) \
    | tee -a "$LOG_FILE"

  log "\n-- Failed services --"
  systemctl --failed --no-legend | tee -a "$LOG_FILE"

  log "\n-- Timers enabled --"
  systemctl list-timers --all --no-legend | tee -a "$LOG_FILE"

  if [[ $APPLY -eq 1 && $AGGRESSIVE -eq 1 && $CRON -eq 0 ]]; then
    log "\nReviewing enabled-but-inactive services interactively..."
    comm -23 \
      <(systemctl list-unit-files --type=service --state=enabled --no-legend | awk '{print $1}' | sort) \
      <(systemctl list-units --type=service --state=running --no-legend | awk '{print $1}' | sort) \
      | while read -r svc; do
          [[ -z "$svc" ]] && continue
          if [[ "$svc" =~ $PROTECTED_SERVICES_REGEX ]]; then
            log "\nSkipping protected service: $svc (never auto-managed)"
            continue
          fi
          log "\nService: $svc"
          systemctl status "$svc" --no-pager 2>/dev/null | head -n 5 | tee -a "$LOG_FILE"
          log "Last 5 journal lines:"
          journalctl -u "$svc" -n 5 --no-pager 2>/dev/null | tee -a "$LOG_FILE"
          if confirm "Disable '$svc' (will not be removed, just disabled from boot)?"; then
            systemctl disable "$svc" | tee -a "$LOG_FILE"
          fi
        done
  elif [[ $CRON -eq 1 ]]; then
    log "\n(--cron mode: skipping aggressive/interactive service review entirely.)"
  else
    log "\n(Use --apply --aggressive, outside of --cron, to interactively review/disable these.)"
  fi
else
  log "systemctl not found — service audit skipped (non-systemd system)."
fi

# ---------------------------------------------------------------------------
# 5. Package usage audit: installed-but-unused candidates (dnf/rpm)
# ---------------------------------------------------------------------------
section "5. Installed packages with no recently-used binaries (heuristic)"

if command -v dnf &>/dev/null; then
  log "This heuristic lists user-installed packages (dnf repoquery --userinstalled)"
  log "whose binaries do not appear in shell history, cron, systemd units, or the"
  log "recent process list. REVIEW CAREFULLY — this is informational, not a"
  log "removal list, unless you explicitly confirm each one in --aggressive mode."

  MANUAL_PKGS=$(dnf repoquery --userinstalled --qf '%{name}' 2>/dev/null)

  RUNNING_BINS=$(ps -eo comm= | sort -u)
  CRON_REFS=$(cat /etc/crontab /etc/cron.*/* 2>/dev/null; crontab -l 2>/dev/null)
  SYSTEMD_REFS=$(grep -h -o '/usr/[^ ]*' /etc/systemd/system/*.service /usr/lib/systemd/system/*.service 2>/dev/null)
  HIST_REFS=""
  for h in /root/.bash_history /home/*/.bash_history; do
    [[ -f "$h" ]] && HIST_REFS+="$(cat "$h" 2>/dev/null) "
  done

  log "\n-- User-installed packages with NO obvious recent usage signal --"
  USAGE_REPORT="$LOG_DIR/unused-packages-$(date +%Y%m%d).txt"
  : > "$USAGE_REPORT"
  for pkg in $MANUAL_PKGS; do
    # Skip core/critical packages
    case "$pkg" in
      kernel*|systemd*|glibc*|grub2*|dnf*|rpm*|bash|coreutils|NetworkManager*|firewalld|openssh-server|sudo|dracut*|selinux-policy*)
        continue
        ;;
    esac

    BINS=$(rpm -ql "$pkg" 2>/dev/null | grep -E '/(usr/)?(s)?bin/' | xargs -n1 basename 2>/dev/null | sort -u)
    [[ -z "$BINS" ]] && continue

    USED=0
    for b in $BINS; do
      if echo "$RUNNING_BINS" | grep -qx "$b" \
         || echo "$CRON_REFS" | grep -q "$b" \
         || echo "$SYSTEMD_REFS" | grep -q "$b" \
         || echo "$HIST_REFS" | grep -qw "$b"; then
        USED=1
        break
      fi
    done

    if [[ $USED -eq 0 ]]; then
      echo "$pkg  (binaries: $(echo "$BINS" | tr '\n' ' '))" | tee -a "$LOG_FILE" >> "$USAGE_REPORT"
    fi
  done
  cat "$USAGE_REPORT" >> "$LOG_FILE" 2>/dev/null

  PREV_REPORT=$(find "$LOG_DIR" -maxdepth 1 -name 'unused-packages-*.txt' ! -name "$(basename "$USAGE_REPORT")" \
                  -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | awk '{print $2}')
  if [[ -n "${PREV_REPORT:-}" && -f "$PREV_REPORT" ]]; then
    log "\n-- Newly-flagged unused packages since previous report ($(basename "$PREV_REPORT")) --"
    comm -23 <(sort "$USAGE_REPORT") <(sort "$PREV_REPORT") | tee -a "$LOG_FILE"
  fi

  find "$LOG_DIR" -name 'unused-packages-*.txt' -mtime +180 -delete 2>/dev/null || true

  if [[ $APPLY -eq 1 && $AGGRESSIVE -eq 1 ]]; then
    log "\nNote: re-run with the list above and use 'dnf remove <pkg>' manually"
    log "after you've verified each one. Interactive per-package removal is"
    log "intentionally not automated here to avoid accidental removal of"
    log "something load-bearing (e.g. networking, ssh tooling)."
  fi
else
  log "Package usage audit is dnf/rpm-specific — skipped (dnf not found)."
fi

# ---------------------------------------------------------------------------
# 6. Network listeners check (sanity check before disabling services)
# ---------------------------------------------------------------------------
section "6. Active network listeners (for cross-reference with services)"

if command -v ss &>/dev/null; then
  ss -tulpn 2>/dev/null | tee -a "$LOG_FILE"
else
  log "'ss' not found, skipping listener check."
fi

# ---------------------------------------------------------------------------
# Summary + notification (cron mode)
# ---------------------------------------------------------------------------
section "Summary"
log "Mode used: $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
log "Full details written to: $LOG_FILE"
log ""

if [[ $CRON -eq 1 ]]; then
  ACTIONS_TAKEN=$(grep -c '^\[ACTION\]' "$LOG_FILE" 2>/dev/null || echo 0)
  if [[ "$ACTIONS_TAKEN" -gt 0 ]]; then
    NOTIF_MSG="rhel-declutter: $ACTIONS_TAKEN action(s) taken. See $LOG_FILE for details."
  else
    NOTIF_MSG="rhel-declutter: Nothing to clean — system already tidy."
  fi

  echo "$NOTIF_MSG" | systemd-cat -t rhel-declutter -p info 2>/dev/null || true

  if who | grep -q .; then
    wall "$NOTIF_MSG" 2>/dev/null || true
  fi

  log "Cron run complete. Actions taken: $ACTIONS_TAKEN."
else
  log "Recommended next steps:"
  log "  1. Review section 4 (enabled-but-inactive services) and section 5"
  log "     (possibly unused packages) carefully — these are heuristics, not facts."
  log "  2. Re-run with --apply to perform the safe steps (updates, autoremove,"
  log "     cache/log/tmp cleanup)."
  log "  3. Re-run with --apply --aggressive to interactively review/disable"
  log "     specific services. Package removals remain manual/deliberate."
  log "  4. Reboot if a kernel update was applied (check for REBOOT REQUIRED above)."
fi

if [[ $JSON -eq 1 ]]; then
  ACTIONS_TAKEN=$(grep -c '^\[ACTION\]' "$LOG_FILE" 2>/dev/null || echo 0)
  REBOOT_REQ=false
  dnf needs-restarting -r >/dev/null 2>&1 || { [[ $? -eq 1 ]] && REBOOT_REQ=true; }
  printf '{"tool":"twdxos","platform":"linux-rhel","script":"declutter","mode":"%s","aggressive":%s,"actions_taken":%s,"reboot_required":%s,"log_file":"%s","timestamp":"%s"}\n' \
    "$([[ $APPLY -eq 1 ]] && echo apply || echo dry-run)" \
    "$([[ $AGGRESSIVE -eq 1 ]] && echo true || echo false)" \
    "${ACTIONS_TAKEN:-0}" "$REBOOT_REQ" "$LOG_FILE" "$(date -Iseconds)" >&3
fi
