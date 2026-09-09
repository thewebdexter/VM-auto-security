#!/usr/bin/env bash
#
# linux-declutter.sh
#
# Goal: Help move a Linux system closer to a "factory default" state by
# identifying (and optionally removing) unused packages, services, and
# leftover files — without breaking the system.
#
# Default mode: REPORT ONLY (dry-run). Nothing is changed unless --apply is given.
#
# Optimized for: Ubuntu 24.04 (Minimal, arm64/aarch64)
# Also works (reduced functionality) on: Debian-based and other distros (detection-only)
#
# Usage:
#   sudo ./linux-declutter.sh            # report only, no changes
#   sudo ./linux-declutter.sh --apply    # actually perform safe cleanup steps
#   sudo ./linux-declutter.sh --apply --aggressive   # also offers to remove
#                                                     # unused-but-installed packages
#                                                     # (asks for confirmation each time)
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
LOG_DIR="/var/log/linux-declutter"
LOG_FILE="$LOG_DIR/linux-declutter-$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/var/run/linux-declutter.lock"
ACTIONS_TAKEN=0

# Services that must NEVER be touched by the aggressive auto-disable step,
# regardless of how they look in the "enabled but inactive" list.
PROTECTED_SERVICES_REGEX='^(ssh|sshd|systemd-|networking|NetworkManager|network-manager|netplan|cloud-init|cron|crond|ufw|resolvconf|systemd-resolved|systemd-networkd|dbus|udev|getty@|serial-getty@)'

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
      echo "                auto-confirms safe steps (update/full-upgrade/autoremove/clean),"
      echo "                skips all interactive --aggressive prompts, and refuses to"
      echo "                disable/remove anything matching the protected-services list."
      exit 0
      ;;
  esac
done

mkdir -p "$LOG_DIR"
# These reports contain a host inventory (listening ports, package/service
# lists) — keep them out of world-readable reach.
chmod 750 "$LOG_DIR" 2>/dev/null || true
umask 027

# Prevent overlapping runs (important for cron)
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "Another instance of $0 is already running (lock: $LOCK_FILE). Exiting." >&2
  exit 1
fi
{ touch "$LOG_FILE" && chmod 640 "$LOG_FILE"; } 2>/dev/null || true

# --json: keep stdout clean for the final machine-readable line; everything
# else goes to the log file.
if [[ $JSON -eq 1 ]]; then exec 3>&1 1>>"$LOG_FILE" 2>&1; fi

# Trim old logs from this script so they don't become clutter themselves
find "$LOG_DIR" -type f -name 'linux-declutter-*.log' -mtime +90 -delete 2>/dev/null || true

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

PKG_MANAGER=""
if command -v apt-get &>/dev/null; then
  PKG_MANAGER="apt"
elif command -v dnf &>/dev/null; then
  PKG_MANAGER="dnf"
elif command -v yum &>/dev/null; then
  PKG_MANAGER="yum"
elif command -v pacman &>/dev/null; then
  PKG_MANAGER="pacman"
elif command -v zypper &>/dev/null; then
  PKG_MANAGER="zypper"
else
  PKG_MANAGER="unknown"
fi

log "Package manager: $PKG_MANAGER"

if [[ "$OS_ID" == "ubuntu" && "$OS_VERSION" == "24.04" ]]; then
  log "Ubuntu 24.04 confirmed — full feature set enabled."
elif [[ "$PKG_MANAGER" == "apt" ]]; then
  log "Debian/Ubuntu-family system detected — apt-based steps enabled."
else
  log "Non-apt system detected. Update/upgrade/autoremove steps for $PKG_MANAGER"
  log "are limited; package-usage analysis is apt/dpkg-specific and will be skipped."
fi

# ---------------------------------------------------------------------------
# 2. Update / Upgrade / Autoremove / Clean (apt-based systems)
# ---------------------------------------------------------------------------
section "2. Package updates, upgrade, autoremove, cache cleanup"

if [[ "$PKG_MANAGER" == "apt" ]]; then
  export DEBIAN_FRONTEND=noninteractive

  log "-- apt-get update (with retry) --"
  if [[ $APPLY -eq 1 ]]; then
    UPDATE_OK=0
    for attempt in 1 2 3; do
      if apt-get update | tee -a "$LOG_FILE"; then
        UPDATE_OK=1
        break
      fi
      log "apt-get update failed (attempt $attempt/3), retrying in 15s..."
      sleep 15
    done
    if [[ $UPDATE_OK -eq 0 ]]; then
      log "apt-get update failed after 3 attempts. Aborting upgrade/autoremove steps for this run."
    fi
  else
    log "(dry-run) would run: apt-get update"
    UPDATE_OK=1
  fi

  log "\n-- Upgradable packages --"
  apt list --upgradable 2>/dev/null | tee -a "$LOG_FILE"

  log "\n-- apt-get full-upgrade (handles dependency/kernel changes properly) --"
  if [[ $APPLY -eq 1 && $UPDATE_OK -eq 1 ]]; then
    if CONFIRM_SAFE=1 confirm "Proceed with 'apt-get full-upgrade -y'?"; then
      apt-get full-upgrade -y >> "$LOG_FILE" 2>&1
      note_action "apt-get full-upgrade completed"
    fi
  elif [[ $APPLY -eq 1 ]]; then
    log "Skipping upgrade because apt-get update failed."
  else
    log "(dry-run) would run: apt-get full-upgrade -y"
  fi

  log "\n-- Packages that would be removed by autoremove --"
  apt-get -s autoremove 2>/dev/null | grep -E '^(Remv|The following packages)' | tee -a "$LOG_FILE"

  if [[ $APPLY -eq 1 ]]; then
    if CONFIRM_SAFE=1 confirm "Proceed with 'apt-get autoremove -y'?"; then
      apt-get autoremove -y >> "$LOG_FILE" 2>&1
      note_action "apt-get autoremove completed"
    fi
  else
    log "(dry-run) would run: apt-get autoremove -y"
  fi

  if [[ $APPLY -eq 1 ]]; then
    apt-get autoclean -y >> "$LOG_FILE" 2>&1
    apt-get clean >> "$LOG_FILE" 2>&1
    note_action "apt cache cleaned"
  else
    log "(dry-run) would run: apt-get autoclean -y && apt-get clean"
  fi

  # Reboot check
  if [[ -f /var/run/reboot-required ]]; then
    REBOOT_PKGS=""
    [[ -f /var/run/reboot-required.pkgs ]] && REBOOT_PKGS=$(tr '\n' ' ' < /var/run/reboot-required.pkgs)
    note_action "REBOOT REQUIRED after package updates. Packages: ${REBOOT_PKGS:-unknown}"
    log "*** REBOOT REQUIRED — schedule one soon to apply kernel/library updates ***"
  fi

else
  log "Skipping apt-specific update/upgrade/autoremove (not an apt system)."
  case "$PKG_MANAGER" in
    dnf|yum) log "Consider: $PKG_MANAGER update && $PKG_MANAGER autoremove && $PKG_MANAGER clean all" ;;
    pacman)  log "Consider: pacman -Syu && pacman -Qtdq | pacman -Rns - (orphans) && pacman -Scc" ;;
    zypper)  log "Consider: zypper refresh && zypper update && zypper clean" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 3. Generic garbage collection (logs, tmp, old kernels, caches)
# ---------------------------------------------------------------------------
section "3. Garbage collection: old kernels, logs, tmp files, journal"

# --- Old kernels (apt only) ---
if [[ "$PKG_MANAGER" == "apt" ]]; then
  CURRENT_KERNEL=$(uname -r)
  log "Current running kernel: $CURRENT_KERNEL"
  log "\n-- Installed kernel packages (current one is kept regardless) --"
  dpkg --list | grep -E '^ii  linux-(image|headers|modules)' | awk '{print $2}' | tee -a "$LOG_FILE"

  # Keep every package whose name ends in the exact running release string
  # (e.g. linux-image-6.8.0-31-generic, linux-image-6.8.0-1010-oracle).
  OLD_KERNELS=$(dpkg --list \
                 | grep -E '^ii  linux-(image|headers|modules|modules-extra)-[0-9]' \
                 | awk '{print $2}' \
                 | grep -vE -- "-${CURRENT_KERNEL}$" || true)

  if [[ -n "$OLD_KERNELS" ]]; then
    log "\nOld kernel packages NOT matching the running kernel ($CURRENT_KERNEL):"
    echo "$OLD_KERNELS" | tee -a "$LOG_FILE"
    if [[ $APPLY -eq 1 && $AGGRESSIVE -eq 1 ]]; then
      if confirm "Purge these old kernel packages? (autoremove already covers most of this)"; then
        # shellcheck disable=SC2086
        apt-get purge -y $OLD_KERNELS | tee -a "$LOG_FILE"
      fi
    else
      log "(Not removed automatically; usually autoremove already handles old kernels.)"
    fi
  else
    log "No old kernel packages found beyond the current one."
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

# Safe temp cleanup: only regular files / symlinks older than 10 days, on the
# same filesystem, never sockets/FIFOs/dirs, and never system-owned runtime
# paths (systemd-private-*, .X11-unix, snap-*, .ICE-unix, ssh-* agents, …).
# systemd-tmpfiles is preferred where present — it honours the OS's own
# per-path age policy instead of a blanket mtime sweep.
TMP_PRUNE=( -name 'systemd-private-*' -o -name '.X11-unix' -o -name '.XIM-unix'
            -o -name '.ICE-unix' -o -name '.font-unix' -o -name '.Test-unix'
            -o -name 'snap.*' -o -name 'snap-private-*' -o -name 'ssh-*'
            -o -name 'gpg-*' -o -name 'dbus-*' -o -name '.esd-*'
            -o -name 'tmux-*' -o -name '.X0-lock' -o -name 'vmware-*' )

log "\n-- Stale regular files in /tmp and /var/tmp (older than 10 days) --"
find /tmp /var/tmp -xdev -mindepth 1 \( "${TMP_PRUNE[@]}" \) -prune -o \
     \( -type f -o -type l \) -mtime +10 -print 2>/dev/null | tee -a "$LOG_FILE"

if [[ $APPLY -eq 1 ]]; then
  if command -v systemd-tmpfiles &>/dev/null; then
    systemd-tmpfiles --clean >> "$LOG_FILE" 2>&1 || true
    note_action "Ran systemd-tmpfiles --clean (honours OS per-path age policy)"
  fi
  DELETED_TMP=$(find /tmp /var/tmp -xdev -mindepth 1 \( "${TMP_PRUNE[@]}" \) -prune -o \
                \( -type f -o -type l \) -mtime +10 -print -delete 2>/dev/null | wc -l)
  [[ "$DELETED_TMP" -gt 0 ]] && note_action "Cleared $DELETED_TMP stale temp files (>10 days, regular files/symlinks only)"
else
  log "(dry-run) would run systemd-tmpfiles --clean and remove the stale regular files listed above."
fi

# --- snap leftovers (Ubuntu) ---
if command -v snap &>/dev/null; then
  log "\n-- Disabled/old snap revisions --"
  snap list --all | awk '/disabled/{print $1, $3}' | tee -a "$LOG_FILE"
  if [[ $APPLY -eq 1 ]]; then
    snap list --all | awk '/disabled/{print $1, $3}' | while read -r sname rev; do
      snap remove "$sname" --revision="$rev" 2>/dev/null \
        && note_action "Removed disabled snap: $sname revision $rev"
    done
  else
    log "(dry-run) would remove disabled snap revisions listed above."
  fi
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
# 5. Package usage audit: installed-but-unused candidates (apt/dpkg)
# ---------------------------------------------------------------------------
section "5. Installed packages with no recently-used binaries (heuristic)"

if [[ "$PKG_MANAGER" == "apt" ]]; then
  log "This heuristic lists manually-installed packages whose binaries do not"
  log "appear in shell history, cron, systemd units, or recent process list."
  log "REVIEW CAREFULLY — this is informational, not a removal list, unless"
  log "you explicitly confirm each one in --aggressive mode."

  # Manually installed packages (not deps), excluding essential/priority-required
  MANUAL_PKGS=$(apt-mark showmanual)

  # Build a list of 'in use' hints: running processes, cron jobs, systemd ExecStart, shell history
  RUNNING_BINS=$(ps -eo comm= | sort -u)
  CRON_REFS=$(cat /etc/crontab /etc/cron.*/* 2>/dev/null; crontab -l 2>/dev/null)
  SYSTEMD_REFS=$(grep -h -o '/usr/[^ ]*' /etc/systemd/system/*.service /lib/systemd/system/*.service 2>/dev/null)
  HIST_REFS=""
  for h in /root/.bash_history /home/*/.bash_history; do
    [[ -f "$h" ]] && HIST_REFS+="$(cat "$h" 2>/dev/null) "
  done

  log "\n-- Manually installed packages with NO obvious recent usage signal --"
  USAGE_REPORT="$LOG_DIR/unused-packages-$(date +%Y%m%d).txt"
  : > "$USAGE_REPORT"
  for pkg in $MANUAL_PKGS; do
    # Skip core/critical packages
    case "$pkg" in
      ubuntu-minimal|ubuntu-standard|linux-*|systemd*|init|grub*|cloud-init|netplan*|openssh-server|sudo|base-files|dpkg|apt*|bash|coreutils)
        continue
        ;;
    esac

    # Get binaries provided by this package
    BINS=$(dpkg -L "$pkg" 2>/dev/null | grep -E '/(usr/)?(s)?bin/' | xargs -n1 basename 2>/dev/null | sort -u)
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
    log "\nNote: re-run with the list above and use 'apt-get purge <pkg>' manually"
    log "after you've verified each one. Interactive per-package purge is"
    log "intentionally not automated here to avoid accidental removal of"
    log "something load-bearing (e.g. networking, ssh tooling)."
  fi
else
  log "Package usage audit is apt/dpkg-specific — skipped on this system."
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
    NOTIF_MSG="linux-declutter: $ACTIONS_TAKEN action(s) taken. See $LOG_FILE for details."
  else
    NOTIF_MSG="linux-declutter: Nothing to clean — system already tidy."
  fi

  # Log to systemd journal (visible via journalctl -t linux-declutter)
  echo "$NOTIF_MSG" | systemd-cat -t linux-declutter -p info 2>/dev/null || true

  # Also broadcast to logged-in terminals if anyone is logged in
  if who | grep -q .; then
    wall "$NOTIF_MSG" 2>/dev/null || true
  fi

  # If running on a desktop Ubuntu (DISPLAY or WAYLAND_DISPLAY set), try notify-send
  if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v notify-send &>/dev/null; then
    notify-send "Linux Declutter" "$NOTIF_MSG" --urgency=low 2>/dev/null || true
  fi

  log "Cron run complete. Actions taken: $ACTIONS_TAKEN."
else
  log "Recommended next steps:"
  log "  1. Review section 4 (enabled-but-inactive services) and section 5"
  log "     (possibly unused packages) carefully — these are heuristics, not facts."
  log "  2. Re-run with --apply to perform the safe steps (updates, autoremove,"
  log "     cache/log/tmp cleanup, disabled snap revisions)."
  log "  3. Re-run with --apply --aggressive to interactively review/disable"
  log "     specific services. Package purges remain manual/deliberate."
  log "  4. Reboot if a kernel update was applied (check for REBOOT REQUIRED above)."
fi

if [[ $JSON -eq 1 ]]; then
  ACTIONS_TAKEN=$(grep -c '^\[ACTION\]' "$LOG_FILE" 2>/dev/null || echo 0)
  REBOOT_REQ=false
  [[ -f /var/run/reboot-required ]] && REBOOT_REQ=true
  printf '{"tool":"twdxos","platform":"linux-debian","script":"declutter","mode":"%s","aggressive":%s,"actions_taken":%s,"reboot_required":%s,"log_file":"%s","timestamp":"%s"}\n' \
    "$([[ $APPLY -eq 1 ]] && echo apply || echo dry-run)" \
    "$([[ $AGGRESSIVE -eq 1 ]] && echo true || echo false)" \
    "${ACTIONS_TAKEN:-0}" "$REBOOT_REQ" "$LOG_FILE" "$(date -Iseconds)" >&3
fi
