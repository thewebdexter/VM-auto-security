#!/usr/bin/env bash
#
# declutter.sh (macOS)
#
# Goal: Help move a Mac closer to a "clean default" state by identifying
# (and optionally removing/disabling) unused Homebrew packages, third-party
# launch agents/daemons, leftover caches/logs, and rarely-used apps —
# WITHOUT touching anything that is part of macOS itself.
#
# Tested against: macOS 26 Tahoe (26.5.1). Also works on Sequoia/Sonoma.
#
# Default mode: REPORT ONLY (dry-run). Nothing is changed unless --apply.
#
# Hard exclusions (never scanned or touched):
#   - /System/*  and  /System/Applications/*
#   - Anything with a CFBundleIdentifier starting with com.apple.*
#   - /Library/Apple/*
#   - launchd jobs under /System/Library/Launch{Agents,Daemons}
#   - ~/Library/Application Support/com.apple.* (Apple Intelligence model data etc.)
#   - /Users/Shared/Relocated Items (macOS Tahoe upgrade artifact — reviewed separately)
#
# macOS 26 Tahoe notes:
#   - Tahoe can move third-party tools to /Users/Shared/Relocated Items during
#     OS updates, especially on Intel Macs (2019-2020 models). This script checks
#     for this folder early so you don't mistake relocated tools for installed ones.
#   - softwareupdate -ia can now trigger a full major-version jump if you are
#     enrolled in a beta seed. --os-updates uses --recommended to limit scope.
#   - Homebrew 5.x is required for Tahoe support. The script verifies this before
#     running any brew commands.
#   - Xcode simulators now also live under ~/Library/Developer/CoreSimulator/Volumes/
#
# Usage:
#   ./declutter.sh                       # report only
#   ./declutter.sh --apply               # safe cleanup (brew, caches, logs, trash)
#   ./declutter.sh --apply --os-updates  # also install recommended macOS updates
#                                               #   (CAUTION: may trigger reboot)
#   ./declutter.sh --apply --aggressive  # interactively review unused apps,
#                                               #   brew leaves, third-party launch
#                                               #   agents/daemons, and terminal-installed
#                                               #   packages for removal
#   ./declutter.sh --cron                # non-interactive safe steps only
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Flags / globals
# ---------------------------------------------------------------------------
APPLY=0
AGGRESSIVE=0
CRON=0
OS_UPDATES=0
JSON=0
SILENT=0  # set to 1 by --cron; suppresses report text, only logs actual actions

LOG_DIR="$HOME/Library/Logs/macos-declutter"
LOG_FILE="$LOG_DIR/macos-declutter-$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="$LOG_DIR/.lock"

CACHE_AGE_DAYS=30      # user caches older than this are candidates for clearing
LOG_AGE_DAYS=30        # ~/Library/Logs files older than this get removed
TRASH_AGE_DAYS=30      # items in ~/.Trash older than this get removed
APP_UNUSED_DAYS=180    # apps not opened in this many days are flagged

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --aggressive) AGGRESSIVE=1 ;;
    --os-updates) OS_UPDATES=1 ;;
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
      echo "Usage: $0 [--apply] [--aggressive] [--os-updates] [--cron] [--json]"
      echo "  --apply       Perform safe actions (default: dry-run/report only)"
      echo "  --aggressive  Interactively review unused apps, brew leaves, and"
      echo "                third-party launch agents/daemons for removal."
      echo "                Ignored under --cron."
      echo "  --os-updates  Also check/install macOS software updates via"
      echo "                'softwareupdate'. May require a restart or trigger"
      echo "                a major OS upgrade — off by default."
      echo "  --cron        Non-interactive mode for scheduled runs. Implies --apply."
      exit 0
      ;;
  esac
done

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR" 2>/dev/null || true
umask 077

# ---------------------------------------------------------------------------
# Lock (no flock on macOS by default) — simple PID-file lock
# ---------------------------------------------------------------------------
if [[ -f "$LOCK_FILE" ]]; then
  OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Another instance (PID $OLD_PID) appears to be running. Exiting." >&2
    exit 1
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# --json: keep stdout clean for the final machine-readable line.
if [[ $JSON -eq 1 ]]; then touch "$LOG_FILE"; exec 3>&1 1>>"$LOG_FILE" 2>&1; fi

# Trim old logs from this script
find "$LOG_DIR" -type f -name 'macos-declutter-*.log' -mtime +90 -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  # In silent/cron mode, only write to log file — no stdout noise
  if [[ $SILENT -eq 1 ]]; then
    echo -e "$@" >> "$LOG_FILE"
  else
    echo -e "$@" | tee -a "$LOG_FILE"
  fi
}
# action_log: always prints even in silent mode — used for actual changes made
action_log() {
  echo -e "[ACTION] $*" | tee -a "$LOG_FILE"
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
      # Silent mode: just do it, log the action
      log "$prompt -> auto-yes"
      return 0
    else
      log "$prompt -> skipped (interactive step, not run in cron)"
      return 1
    fi
  fi
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# Determine the "real" (console) user, since Homebrew/mas must not run as root.
if [[ $EUID -eq 0 ]]; then
  REAL_USER=$(stat -f%Su /dev/console 2>/dev/null || echo "${SUDO_USER:-root}")
else
  REAL_USER="$(whoami)"
fi
REAL_HOME=$(eval echo "~$REAL_USER")

run_as_user() {
  # run_as_user <command...>
  if [[ $EUID -eq 0 && "$REAL_USER" != "root" ]]; then
    sudo -u "$REAL_USER" -H "$@"
  else
    "$@"
  fi
}

log "Log file: $LOG_FILE"
log "Mode: $([[ $APPLY -eq 1 ]] && echo APPLY || echo "DRY-RUN report only")"
[[ $AGGRESSIVE -eq 1 ]] && log "Aggressive mode: ON"
[[ $OS_UPDATES -eq 1 ]] && log "OS updates: ENABLED (--os-updates)"
log "Running as: $(whoami) (console user for brew/mas: $REAL_USER)"

# Track what was actually cleaned for the summary notification
ACTIONS_TAKEN=0
note_action() {
  ACTIONS_TAKEN=$((ACTIONS_TAKEN + 1))
  action_log "$*"
}

# ---------------------------------------------------------------------------
# 1. OS Detection
# ---------------------------------------------------------------------------
section "1. OS Detection"

PRODUCT_NAME=$(sw_vers -productName 2>/dev/null || echo "macOS")
PRODUCT_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
BUILD_VERSION=$(sw_vers -buildVersion 2>/dev/null || echo "unknown")
ARCH=$(uname -m)

log "Detected: $PRODUCT_NAME $PRODUCT_VERSION (build $BUILD_VERSION)"
log "Architecture: $ARCH $( [[ "$ARCH" == "arm64" ]] && echo "(Apple Silicon)" || echo "(Intel)" )"

# macOS Tahoe / version awareness
OS_MAJOR="${PRODUCT_VERSION%%.*}"
IS_TAHOE=0
[[ "$OS_MAJOR" -ge 26 ]] 2>/dev/null && IS_TAHOE=1
if [[ $IS_TAHOE -eq 1 ]]; then
  log "macOS 26 Tahoe detected — Tahoe-specific checks enabled."
  if [[ "$ARCH" == "x86_64" ]]; then
    log ""
    log "*** INTEL MAC WARNING ***"
    log "macOS Tahoe 26 has a known bug on 2019-2020 Intel MacBook Pros where"
    log "OS updates move third-party tools (Homebrew, Docker, Python, apps) to"
    log "/Users/Shared/Relocated Items and DELETE items from /usr/local."
    log "This script will check that folder next. Do NOT run cleanup until you"
    log "have checked what is in there and restored anything you still need."
    log "*************************"
  fi
fi

# macOS Tahoe: check for Relocated Items left by OS update
RELOCATED_DIR="/Users/Shared/Relocated Items"
ALT_RELOCATED="$REAL_HOME/Library/Shared/Security/Moved Items"
for rdir in "$RELOCATED_DIR" "$ALT_RELOCATED"; do
  if [[ -d "$rdir" ]]; then
    log ""
    log "*** RELOCATED ITEMS FOUND: $rdir ***"
    log "macOS moved the following items here during an OS update."
    log "Review them BEFORE running any cleanup — these are NOT safe to delete"
    log "automatically. Restore what you still need, then delete the folder."
    find "$rdir" -maxdepth 2 -mindepth 1 2>/dev/null | head -n 40 | tee -a "$LOG_FILE"
    RDIR_COUNT=$(find "$rdir" -maxdepth 2 -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
    [[ "$RDIR_COUNT" -gt 40 ]] && log "  ... and $((RDIR_COUNT - 40)) more items. Open Finder to browse the full folder."
    log "***"
  fi
done

# Homebrew location differs by architecture
BREW_BIN=""
if [[ "$ARCH" == "arm64" && -x /opt/homebrew/bin/brew ]]; then
  BREW_BIN=/opt/homebrew/bin/brew
elif [[ -x /usr/local/bin/brew ]]; then
  BREW_BIN=/usr/local/bin/brew
elif command -v brew &>/dev/null; then
  BREW_BIN=$(command -v brew)
fi

if [[ -n "$BREW_BIN" ]]; then
  # Validate Homebrew actually works (Tahoe can leave it broken after an update)
  BREW_VERSION=$(run_as_user "$BREW_BIN" --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
  BREW_MAJOR="${BREW_VERSION%%.*}"
  if run_as_user "$BREW_BIN" config &>/dev/null; then
    log "Homebrew found and working: $BREW_BIN (version $BREW_VERSION)"
    if [[ $IS_TAHOE -eq 1 && "${BREW_MAJOR:-0}" -lt 5 ]]; then
      log "WARNING: Homebrew $BREW_VERSION may not fully support macOS Tahoe."
      log "Run: brew update && brew upgrade  to get Homebrew 5.x before using this script."
      log "Homebrew steps will still run but may report errors."
    fi
    brew() { run_as_user "$BREW_BIN" "$@"; }
  else
    log "Homebrew found at $BREW_BIN but appears broken (brew config failed)."
    if [[ $IS_TAHOE -eq 1 ]]; then
      log "This is a known macOS Tahoe issue. To fix:"
      log "  1. Check /Users/Shared/Relocated Items for your old Homebrew files."
      log "  2. Run: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
      log "  3. Re-run this script after Homebrew is reinstalled."
    fi
    log "Skipping all Homebrew steps for this run."
    BREW_BIN=""
  fi
else
  log "Homebrew not found — Homebrew-related steps will be skipped."
fi

MAS_BIN=$(command -v mas 2>/dev/null || echo "")
[[ -n "$MAS_BIN" ]] && log "mas (App Store CLI) found: $MAS_BIN"

if [[ -d /opt/local/bin && -x /opt/local/bin/port ]]; then
  log "MacPorts detected at /opt/local — this script focuses on Homebrew;"
  log "review MacPorts packages separately with 'port installed' / 'port outdated'."
fi

# ---------------------------------------------------------------------------
# 2. Software updates
# ---------------------------------------------------------------------------
section "2. Software updates"

log "-- macOS software updates (softwareupdate -l) --"
softwareupdate -l 2>&1 | tee -a "$LOG_FILE"

if [[ $OS_UPDATES -eq 1 ]]; then
  if [[ $EUID -ne 0 ]]; then
    log "\n--os-updates was requested but this script is not running as root."
    log "Re-run with sudo to install macOS updates, e.g.:"
    log "  sudo $0 --apply --os-updates"
  else
    if [[ $APPLY -eq 1 ]]; then
      log "\nCAUTION: On macOS 26 Tahoe, 'softwareupdate -ia' can trigger a full"
      log "major-version upgrade (e.g. to macOS 27) if your Mac is enrolled in a"
      log "beta seed program. This script uses '--recommended' to limit installs"
      log "to stable, recommended updates only — not all available updates."
      log "If you are on a beta seed and want to stay on 26.x, decline here."
      if CONFIRM_SAFE=0 confirm "Proceed with 'softwareupdate -i -r' (recommended updates only)?"; then
        softwareupdate -i -r 2>&1 | tee -a "$LOG_FILE"
        if [[ -f /var/db/.SoftwareUpdateRequireRestart || \
              -f /var/run/com.apple.SoftwareUpdate.requireRestart ]]; then
          log "\n*** A RESTART IS REQUIRED to complete macOS updates. ***"
        fi
      else
        log "Skipped macOS update install by user choice."
      fi
    else
      log "(dry-run) would run: softwareupdate -i -a (after confirmation)"
    fi
  fi
else
  log "\n(--os-updates not set: macOS updates are listed above but not installed."
  log " This is intentional — OS upgrades can be disruptive on an unattended schedule.)"
fi

if [[ -n "$BREW_BIN" ]]; then
  log "\n-- Homebrew update --"
  if [[ $APPLY -eq 1 ]]; then
    brew update 2>&1 | tee -a "$LOG_FILE"
  else
    log "(dry-run) would run: brew update"
  fi

  log "\n-- Outdated formulae/casks --"
  brew outdated 2>&1 | tee -a "$LOG_FILE"

  log "\n-- Upgrading formulae (CLI tools / libraries) --"
  if [[ $APPLY -eq 1 ]]; then
    if CONFIRM_SAFE=0 confirm "Proceed with 'brew upgrade --formula'?"; then
      brew upgrade --formula 2>&1 | tee -a "$LOG_FILE"
    else
      log "Skipped formula upgrade by user choice."
    fi
  else
    log "(dry-run) would run: brew upgrade --formula"
  fi

  log "\n-- Upgrading casks (GUI apps) --"
  log "NOTE: cask upgrades can quit running apps (e.g. browsers) to replace them,"
  log "which may interrupt unsaved work. Treated as a confirm-required step even in"
  log "cron mode (auto-declined under --cron unless you remove this safeguard)."
  if [[ $APPLY -eq 1 ]]; then
    if CONFIRM_SAFE=0 confirm "Proceed with 'brew upgrade --cask --greedy'?"; then
      brew upgrade --cask --greedy 2>&1 | tee -a "$LOG_FILE"
    else
      log "Skipped cask upgrade (manual run recommended)."
    fi
  else
    log "(dry-run) would run: brew upgrade --cask --greedy (after confirmation)"
  fi
fi

if [[ -n "$MAS_BIN" ]]; then
  log "\n-- Mac App Store updates (mas) --"
  run_as_user "$MAS_BIN" outdated 2>&1 | tee -a "$LOG_FILE"
  if [[ $APPLY -eq 1 ]]; then
    if CONFIRM_SAFE=0 confirm "Proceed with 'mas upgrade'?"; then
      run_as_user "$MAS_BIN" upgrade 2>&1 | tee -a "$LOG_FILE"
    fi
  else
    log "(dry-run) would run: mas upgrade"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Garbage collection: Homebrew cache, user caches, logs, trash, Xcode
# ---------------------------------------------------------------------------
section "3. Garbage collection"

if [[ -n "$BREW_BIN" ]]; then
  log "-- Homebrew cleanup (old versions + download cache) --"
  if [[ $APPLY -eq 1 ]]; then
    brew cleanup -s --prune=all 2>&1 | tee -a "$LOG_FILE"
  else
    brew cleanup -n 2>&1 | tee -a "$LOG_FILE"
    log "(dry-run, shown above via 'brew cleanup -n')"
  fi

  log "\n-- Homebrew autoremove (orphaned dependencies) --"
  if [[ $APPLY -eq 1 ]]; then
    if CONFIRM_SAFE=0 confirm "Proceed with 'brew autoremove'?"; then
      brew autoremove 2>&1 | tee -a "$LOG_FILE"
    fi
  else
    log "(dry-run) would run: brew autoremove (after confirmation)"
  fi
fi

log "\n-- User cache usage: \$HOME/Library/Caches (top 15 by size) --"
du -sh "$REAL_HOME"/Library/Caches/*/ 2>/dev/null | sort -rh | head -n 15 | tee -a "$LOG_FILE"

log "\n-- Cache subfolders not modified in $CACHE_AGE_DAYS+ days --"
log "  (Excluding com.apple.* — those are OS/Apple Intelligence caches, not yours)"
find "$REAL_HOME/Library/Caches" -maxdepth 1 -mindepth 1 -type d -mtime +"$CACHE_AGE_DAYS" 2>/dev/null \
  | grep -v '/com\.apple\.' | tee -a "$LOG_FILE"

if [[ $APPLY -eq 1 ]]; then
  if CONFIRM_SAFE=1 confirm "Clear cache subfolders older than $CACHE_AGE_DAYS days listed above? (apps will regenerate them as needed)"; then
    find "$REAL_HOME/Library/Caches" -maxdepth 1 -mindepth 1 -type d -mtime +"$CACHE_AGE_DAYS" \
      | grep -v '/com\.apple\.' \
      | while IFS= read -r d; do
          rm -rf "$d" && note_action "Removed stale cache: $d"
        done
  fi
else
  log "(dry-run) would clear the non-Apple cache folders listed above (after confirmation)"
fi

log "\n-- \$HOME/Library/Logs files older than $LOG_AGE_DAYS days --"
find "$REAL_HOME/Library/Logs" -type f -mtime +"$LOG_AGE_DAYS" 2>/dev/null | tee -a "$LOG_FILE"
if [[ $APPLY -eq 1 ]]; then
  find "$REAL_HOME/Library/Logs" -type f -mtime +"$LOG_AGE_DAYS" -print -delete 2>/dev/null \
    | while IFS= read -r f; do note_action "Deleted old log: $f"; done
else
  log "(dry-run) would delete the log files listed above."
fi

log "\n-- Items in ~/.Trash older than $TRASH_AGE_DAYS days --"
find "$REAL_HOME/.Trash" -mindepth 1 -mtime +"$TRASH_AGE_DAYS" 2>/dev/null | tee -a "$LOG_FILE"
if [[ $APPLY -eq 1 ]]; then
  if CONFIRM_SAFE=1 confirm "Permanently delete the items above from Trash?"; then
    find "$REAL_HOME/.Trash" -mindepth 1 -mtime +"$TRASH_AGE_DAYS" -print -exec rm -rf {} + 2>/dev/null | tee -a "$LOG_FILE"
  fi
else
  log "(dry-run) would permanently delete the Trash items listed above."
fi

# Xcode leftovers (only if Xcode/CLT footprint detected)
if [[ -d "$REAL_HOME/Library/Developer/Xcode/DerivedData" ]]; then
  log "\n-- Xcode DerivedData size --"
  du -sh "$REAL_HOME/Library/Developer/Xcode/DerivedData" 2>/dev/null | tee -a "$LOG_FILE"
  if [[ $APPLY -eq 1 ]]; then
    if CONFIRM_SAFE=1 confirm "Clear Xcode DerivedData (safe — regenerated on next build)?"; then
      rm -rf "$REAL_HOME/Library/Developer/Xcode/DerivedData"/* 2>/dev/null
      log "DerivedData cleared."
    fi
  else
    log "(dry-run) would clear DerivedData contents."
  fi

  if command -v xcrun &>/dev/null; then
    log "\n-- Unavailable iOS/watchOS/tvOS simulators --"
    run_as_user xcrun simctl list 2>/dev/null | grep -i unavailable | tee -a "$LOG_FILE"
    if [[ $APPLY -eq 1 ]]; then
      if CONFIRM_SAFE=1 confirm "Delete unavailable simulators ('xcrun simctl delete unavailable')?"; then
        # --include-system is intentionally omitted — that would remove Apple's
        # bundled simulator runtimes which are expensive to re-download.
        run_as_user xcrun simctl delete unavailable 2>&1 | tee -a "$LOG_FILE"
      fi
    else
      log "(dry-run) would run: xcrun simctl delete unavailable (after confirmation)"
    fi

    # macOS Tahoe: simulators also stored under CoreSimulator/Volumes
    SIM_VOLUMES="$REAL_HOME/Library/Developer/CoreSimulator/Volumes"
    if [[ -d "$SIM_VOLUMES" ]]; then
      log "\n-- CoreSimulator/Volumes (Tahoe+) size --"
      du -sh "$SIM_VOLUMES" 2>/dev/null | tee -a "$LOG_FILE"
      log "  Individual runtime volumes:"
      du -sh "$SIM_VOLUMES"/*/ 2>/dev/null | sort -rh | tee -a "$LOG_FILE"
      log "  (Remove unused runtime volumes via: xcrun simctl runtime delete <identifier>)"
      log "  (Or: Xcode → Settings → Platforms → select runtime → minus button)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. Launch Agents/Daemons audit (third-party only — Apple ones excluded)
# ---------------------------------------------------------------------------
section "4. Launch Agents / Daemons (third-party only)"

log "Apple's own jobs under /System/Library/Launch{Agents,Daemons} and any"
log "com.apple.* labels are excluded from this audit entirely."

THIRDPARTY_DIRS=(
  "$REAL_HOME/Library/LaunchAgents"
  "/Library/LaunchAgents"
  "/Library/LaunchDaemons"
)

for dir in "${THIRDPARTY_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  log "\n-- $dir --"
  for plist in "$dir"/*.plist; do
    [[ -e "$plist" ]] || continue
    label=$(basename "$plist" .plist)
    case "$label" in com.apple.*) continue ;; esac

    PROGRAM=$(/usr/libexec/PlistBuddy -c "Print :Program" "$plist" 2>/dev/null \
              || /usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$plist" 2>/dev/null)

    LOADED="not loaded"
    if launchctl list 2>/dev/null | grep -q "$label"; then
      LOADED="loaded"
    fi

    ORPHAN=""
    if [[ -n "$PROGRAM" && ! -e "$PROGRAM" ]]; then
      ORPHAN=" [ORPHAN: target binary missing: $PROGRAM]"
    fi

    log "  $label — $LOADED${ORPHAN:+  $ORPHAN}"

    # Orphans are unambiguous — binary is confirmed missing. Remove under --apply,
    # no need for --aggressive. Require sudo for /Library paths.
    if [[ $APPLY -eq 1 && $CRON -eq 0 && -n "$ORPHAN" ]]; then
      if confirm "    Remove orphaned job '$label'? (its binary no longer exists — plist backed up, not deleted)"; then
        launchctl unload "$plist" 2>/dev/null || true
        mkdir -p "$LOG_DIR/removed-plists"
        if [[ "$plist" == /Library/* ]]; then
          sudo mv "$plist" "$LOG_DIR/removed-plists/" 2>/dev/null \
            && note_action "Removed orphaned plist: $plist → $LOG_DIR/removed-plists/"
        else
          mv "$plist" "$LOG_DIR/removed-plists/" 2>/dev/null \
            && note_action "Removed orphaned plist: $plist → $LOG_DIR/removed-plists/"
        fi
      fi
    elif [[ $CRON -eq 1 && -n "$ORPHAN" ]]; then
      # --cron is REPORT-ONLY here (changed in v2.0.0). "Target binary missing"
      # is a heuristic that false-positives on wrapper scripts, relative
      # ProgramArguments, and paths on not-yet-mounted volumes — unattended
      # removal of a third-party LaunchDaemon is too risky. Flag it; a human
      # removes it with an interactive `--apply` run.
      log "  [orphan — review] $label: $ORPHAN"
      log "         (run 'twdxos-declutter.sh --apply' interactively to remove it)"
    fi
  done
done

if [[ $CRON -eq 1 ]]; then
  log "\n(--cron mode: launch agent/daemon review is informational only, nothing changed.)"
elif [[ $APPLY -eq 0 ]]; then
  log "\n(Re-run with --apply to be prompted to remove orphaned jobs shown above.)"
fi

# ---------------------------------------------------------------------------
# 5. App & Homebrew package usage audit
# ---------------------------------------------------------------------------
section "5. Apps and Homebrew packages: usage review"

log "Apps under /System/Applications and anything with a com.apple.* bundle"
log "identifier are excluded from this audit."

log "\n-- Apps in /Applications and ~/Applications not opened in $APP_UNUSED_DAYS+ days --"
for appdir in /Applications "$REAL_HOME/Applications"; do
  [[ -d "$appdir" ]] || continue
  while IFS= read -r -d '' app; do
    BUNDLE_ID=$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")
    case "$BUNDLE_ID" in com.apple.*) continue ;; esac

    LAST_USED=$(mdls -name kMDItemLastUsedDate -raw "$app" 2>/dev/null)
    if [[ "$LAST_USED" == "(null)" || -z "$LAST_USED" ]]; then
      # Spotlight may not have data — fall back to install/modification date
      LAST_USED_EPOCH=$(stat -f%m "$app" 2>/dev/null || echo 0)
      SOURCE="mtime (Spotlight data unavailable)"
    else
      LAST_USED_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$LAST_USED" "+%s" 2>/dev/null \
                         || date -j -f "%Y-%m-%d %H:%M:%S" "${LAST_USED% *}" "+%s" 2>/dev/null \
                         || echo 0)
      SOURCE="Spotlight last-used"
    fi

    NOW_EPOCH=$(date +%s)
    AGE_DAYS=$(( (NOW_EPOCH - LAST_USED_EPOCH) / 86400 ))

    if [[ $AGE_DAYS -ge $APP_UNUSED_DAYS ]]; then
      echo "$app  (last used ~$AGE_DAYS days ago, source: $SOURCE)" | tee -a "$LOG_FILE"
    fi
  done < <(find "$appdir" -maxdepth 1 -name '*.app' -print0 2>/dev/null)
done

log "\nNote: macOS only tracks 'last used' via Spotlight (mdls). If Spotlight"
log "indexing is off for a volume, this falls back to file modification time,"
log "which is less reliable. Treat this list as a starting point, not fact."

if [[ -n "$BREW_BIN" ]]; then
  log "\n-- Homebrew 'leaves' (installed formulae with nothing depending on them) --"
  brew leaves 2>&1 | tee -a "$LOG_FILE"
  log "\nThese are candidates for review — being a 'leaf' means nothing else"
  log "depends on them, not that they're unused. Cross-check before removing."

  log "\n-- Installed casks --"
  brew list --cask 2>&1 | tee -a "$LOG_FILE"
fi

if [[ $APPLY -eq 1 && $AGGRESSIVE -eq 1 && $CRON -eq 0 ]]; then
  log "\n-- Interactive review: unused apps found above --"
  for appdir in /Applications "$REAL_HOME/Applications"; do
    [[ -d "$appdir" ]] || continue
    while IFS= read -r -d '' app; do
      BUNDLE_ID=$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")
      case "$BUNDLE_ID" in com.apple.*) continue ;; esac
      LAST_USED=$(mdls -name kMDItemLastUsedDate -raw "$app" 2>/dev/null)
      LAST_USED_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$LAST_USED" "+%s" 2>/dev/null || echo 0)
      AGE_DAYS=$(( ($(date +%s) - LAST_USED_EPOCH) / 86400 ))
      [[ $AGE_DAYS -lt $APP_UNUSED_DAYS ]] && continue

      if confirm "Move '$app' to Trash (last used ~$AGE_DAYS days ago)?"; then
        mv "$app" "$REAL_HOME/.Trash/" 2>/dev/null \
          && log "Moved $app to Trash. Empty Trash manually once you're sure."
      fi
    done < <(find "$appdir" -maxdepth 1 -name '*.app' -print0 2>/dev/null)
  done

  if [[ -n "$BREW_BIN" ]]; then
    log "\n-- Interactive review: Homebrew leaves --"
    for leaf in $(brew leaves 2>/dev/null); do
      if confirm "Uninstall Homebrew formula '$leaf'?"; then
        brew uninstall "$leaf" 2>&1 | tee -a "$LOG_FILE"
      fi
    done
  fi
elif [[ $CRON -eq 1 ]]; then
  log "\n(--cron mode: app/package usage review above is informational only.)"
else
  log "\n(Use --apply --aggressive, outside of --cron, to interactively act on the above.)"
fi

# ---------------------------------------------------------------------------
# 6. Network listeners (sanity check)
# ---------------------------------------------------------------------------
section "6. Active network listeners"
sudo -n lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | tee -a "$LOG_FILE" \
  || lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | tee -a "$LOG_FILE"

# ---------------------------------------------------------------------------
# 7. Other terminal-installed sources: pip/npm/gem/cargo/go, version managers,
#    manually-placed binaries, and shell config audit
# ---------------------------------------------------------------------------
section "7. Other terminal-installed sources & shell config audit"

INTERACTIVE_CLEANUP=0
[[ $APPLY -eq 1 && $AGGRESSIVE -eq 1 && $CRON -eq 0 ]] && INTERACTIVE_CLEANUP=1

# Helper: confirm + run an uninstall command for one named package.
# Usage: review_and_remove "display name" "uninstall command..."
review_and_remove() {
  local name="$1"; shift
  if confirm "  Remove '$name'?"; then
    "$@" 2>&1 | tee -a "$LOG_FILE"
  fi
}

log "This section is informational/read-only for shell config files — dotfiles"
log "are never edited automatically (a bad automated edit could break your shell"
log "entirely)."
log ""
log "For pip/pipx/npm/gem/cargo packages, go binaries, and old language-version"
log "installs, --apply --aggressive (outside --cron) will go through each one"
log "and ask before removing it. 'Last used' data isn't available for these,"
log "so YOU are the judge — if you don't recognize a name or aren't sure,"
log "say no; you can always reinstall it later if it turns out you needed it."
log "Uninstalling a library (vs. a standalone CLI tool) can occasionally break"
log "something else that depends on it — when in doubt, skip it."

# --- pip / pipx ---
if command -v python3 &>/dev/null; then
  log "\n-- Python: pip user-installed packages (pip3 list --user) --"
  PIP_PKGS=$(run_as_user python3 -m pip list --user --format=freeze 2>/dev/null)
  echo "$PIP_PKGS" | tee -a "$LOG_FILE"

  if [[ $INTERACTIVE_CLEANUP -eq 1 && -n "$PIP_PKGS" ]]; then
    log "\n-- Interactive review: pip user packages --"
    while IFS='=' read -r pkgname _; do
      [[ -z "$pkgname" ]] && continue
      review_and_remove "pip: $pkgname" run_as_user python3 -m pip uninstall -y "$pkgname"
    done < <(echo "$PIP_PKGS")
  fi
fi
if command -v pipx &>/dev/null; then
  log "\n-- pipx-managed tools --"
  PIPX_PKGS=$(run_as_user pipx list --short 2>/dev/null)
  echo "$PIPX_PKGS" | tee -a "$LOG_FILE"

  if [[ $INTERACTIVE_CLEANUP -eq 1 && -n "$PIPX_PKGS" ]]; then
    log "\n-- Interactive review: pipx tools --"
    while read -r pkgname _; do
      [[ -z "$pkgname" ]] && continue
      review_and_remove "pipx: $pkgname" run_as_user pipx uninstall "$pkgname"
    done < <(echo "$PIPX_PKGS")
  fi
fi

# --- npm ---
if command -v npm &>/dev/null; then
  log "\n-- npm: globally installed packages --"
  NPM_PKGS=$(run_as_user npm ls -g --depth=0 2>/dev/null)
  echo "$NPM_PKGS" | tee -a "$LOG_FILE"

  if [[ $INTERACTIVE_CLEANUP -eq 1 ]]; then
    log "\n-- Interactive review: npm global packages --"
    # Lines look like "├── pkgname@1.2.3" or "└── pkgname@1.2.3"; skip the root "npm@..." line.
    while read -r pkgname; do
      [[ -z "$pkgname" || "$pkgname" == "npm" ]] && continue
      review_and_remove "npm -g: $pkgname" run_as_user npm uninstall -g "$pkgname"
    done < <(echo "$NPM_PKGS" | grep -oE '[a-zA-Z0-9@/_.-]+@[0-9][a-zA-Z0-9.+-]*' | sed -E 's/@[^@]*$//')
  fi

  NPM_CACHE_DIR=$(run_as_user npm config get cache 2>/dev/null)
  if [[ -d "$NPM_CACHE_DIR" ]]; then
    log "npm cache size ($NPM_CACHE_DIR):"
    du -sh "$NPM_CACHE_DIR" 2>/dev/null | tee -a "$LOG_FILE"
    if [[ $APPLY -eq 1 ]]; then
      if CONFIRM_SAFE=1 confirm "Run 'npm cache clean --force' to clear npm's cache (safe, re-downloads on demand)?"; then
        run_as_user npm cache clean --force 2>&1 | tee -a "$LOG_FILE"
      fi
    else
      log "(dry-run) would run: npm cache clean --force (after confirmation)"
    fi
  fi
fi

# --- gem ---
if command -v gem &>/dev/null; then
  log "\n-- Ruby gems (gem list --local) --"
  GEM_PKGS=$(run_as_user gem list --local 2>/dev/null)

  # Separate default (system) gems from user-installed ones for clarity
  GEM_DEFAULT=$(echo "$GEM_PKGS" | grep '(default:')
  GEM_INSTALLED=$(echo "$GEM_PKGS" | grep -v '(default:')

  log "  System/default gems (shipped with macOS Ruby — do not remove):"
  echo "$GEM_DEFAULT" | sed 's/^/    /' | tee -a "$LOG_FILE"

  log "  User-installed gems (candidates for removal):"
  if [[ -n "$GEM_INSTALLED" ]]; then
    echo "$GEM_INSTALLED" | sed 's/^/    /' | tee -a "$LOG_FILE"
  else
    log "    (none)"
  fi

  if [[ $INTERACTIVE_CLEANUP -eq 1 && -n "$GEM_INSTALLED" ]]; then
    log "\n-- Interactive review: user-installed Ruby gems --"
    log "  (If a gem refuses to uninstall, it may be a dependency of another gem — that's fine, skip it.)"
    while read -r gemname _; do
      [[ -z "$gemname" ]] && continue
      review_and_remove "gem: $gemname" sudo gem uninstall "$gemname" -a -x
    done < <(echo "$GEM_INSTALLED" | awk '{print $1}')
  fi
fi

# --- cargo / rust ---
if command -v cargo &>/dev/null; then
  log "\n-- cargo: binaries installed via 'cargo install --list' --"
  CARGO_PKGS=$(run_as_user cargo install --list 2>/dev/null)
  echo "$CARGO_PKGS" | tee -a "$LOG_FILE"

  if [[ $INTERACTIVE_CLEANUP -eq 1 && -n "$CARGO_PKGS" ]]; then
    log "\n-- Interactive review: cargo-installed binaries --"
    while read -r pkgname _; do
      [[ -z "$pkgname" ]] && continue
      review_and_remove "cargo: $pkgname" run_as_user cargo uninstall "$pkgname"
    done < <(echo "$CARGO_PKGS" | grep -E '^[a-zA-Z0-9_-]+ v[0-9]' | awk '{print $1}')
  fi
fi
if [[ -d "$REAL_HOME/.cargo" ]]; then
  log "\$HOME/.cargo size:"
  du -sh "$REAL_HOME/.cargo" 2>/dev/null | tee -a "$LOG_FILE"
fi
if [[ -d "$REAL_HOME/.rustup" ]]; then
  log "\$HOME/.rustup size (toolchains/targets):"
  du -sh "$REAL_HOME/.rustup" 2>/dev/null | tee -a "$LOG_FILE"
  log "Installed toolchains:"
  run_as_user rustup toolchain list 2>/dev/null | sed 's/^/  /' | tee -a "$LOG_FILE"
fi

# --- go ---
if command -v go &>/dev/null; then
  GOPATH_BIN="$(run_as_user go env GOPATH 2>/dev/null)/bin"
  if [[ -d "$GOPATH_BIN" ]]; then
    log "\n-- go: binaries installed via 'go install' ($GOPATH_BIN) --"
    find "$GOPATH_BIN" -maxdepth 1 -type f -print0 2>/dev/null \
      | xargs -0 ls -la 2>/dev/null | tee -a "$LOG_FILE"

    if [[ $INTERACTIVE_CLEANUP -eq 1 ]]; then
      log "\n-- Interactive review: go-installed binaries --"
      mkdir -p "$LOG_DIR/quarantined-bin"
      for f in "$GOPATH_BIN"/*; do
        [[ -f "$f" ]] || continue
        if confirm "  Quarantine '$f' (moves to $LOG_DIR/quarantined-bin/, recoverable)?"; then
          mv "$f" "$LOG_DIR/quarantined-bin/" 2>/dev/null \
            && log "Moved $f to $LOG_DIR/quarantined-bin/"
        fi
      done
    fi
  fi
fi

# --- Language version managers: disk usage & installed versions ---
log "\n-- Language version managers: disk usage & installed versions --"

quarantine_version_dir() {
  # quarantine_version_dir <manager_label> <full_path> <version_name>
  local label="$1" path="$2" ver="$3"
  mkdir -p "$LOG_DIR/quarantined-bin"
  if confirm "  Quarantine $label version '$ver' (moves $path to $LOG_DIR/quarantined-bin/, recoverable)?"; then
    mv "$path" "$LOG_DIR/quarantined-bin/${label}-${ver}" 2>/dev/null \
      && log "Moved $path to $LOG_DIR/quarantined-bin/${label}-${ver}"
  fi
}

if [[ -d "$REAL_HOME/.nvm" ]]; then
  log "nvm (~/.nvm):"
  du -sh "$REAL_HOME/.nvm" 2>/dev/null | tee -a "$LOG_FILE"
  NVM_CURRENT=$(cat "$REAL_HOME/.nvm/alias/default" 2>/dev/null || echo "")
  log "  Default/current alias: ${NVM_CURRENT:-unknown}"
  log "  Installed Node versions:"
  find "$REAL_HOME/.nvm/versions/node" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sed 's/^/    /' | tee -a "$LOG_FILE"

  if [[ $INTERACTIVE_CLEANUP -eq 1 ]]; then
    log "\n-- Interactive review: old Node versions (nvm) --"
    while IFS= read -r -d '' vdir; do
      v=$(basename "$vdir")
      if [[ -n "$NVM_CURRENT" && "$v" == *"$NVM_CURRENT"* ]]; then
        log "  Skipping $v (matches default/current alias '$NVM_CURRENT')"
        continue
      fi
      quarantine_version_dir "nvm-node" "$vdir" "$v"
    done < <(find "$REAL_HOME/.nvm/versions/node" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi
fi

if [[ -d "$REAL_HOME/.pyenv" ]]; then
  log "pyenv (~/.pyenv):"
  du -sh "$REAL_HOME/.pyenv" 2>/dev/null | tee -a "$LOG_FILE"
  PYENV_GLOBAL=$(cat "$REAL_HOME/.pyenv/version" 2>/dev/null || echo "")
  log "  Installed Python versions:"
  find "$REAL_HOME/.pyenv/versions" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sed 's/^/    /' | tee -a "$LOG_FILE"
  log "  Global pyenv version: ${PYENV_GLOBAL:-unknown}"

  if [[ $INTERACTIVE_CLEANUP -eq 1 ]]; then
    log "\n-- Interactive review: old Python versions (pyenv) --"
    while IFS= read -r -d '' vdir; do
      v=$(basename "$vdir")
      if [[ "$v" == "$PYENV_GLOBAL" ]]; then
        log "  Skipping $v (matches global pyenv version)"
        continue
      fi
      quarantine_version_dir "pyenv" "$vdir" "$v"
    done < <(find "$REAL_HOME/.pyenv/versions" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi
fi

if [[ -d "$REAL_HOME/.rbenv" ]]; then
  log "rbenv (~/.rbenv):"
  du -sh "$REAL_HOME/.rbenv" 2>/dev/null | tee -a "$LOG_FILE"
  RBENV_GLOBAL=$(cat "$REAL_HOME/.rbenv/version" 2>/dev/null || echo "")
  log "  Installed Ruby versions:"
  find "$REAL_HOME/.rbenv/versions" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>/dev/null | sed 's/^/    /' | tee -a "$LOG_FILE"
  log "  Global rbenv version: ${RBENV_GLOBAL:-unknown}"

  if [[ $INTERACTIVE_CLEANUP -eq 1 ]]; then
    log "\n-- Interactive review: old Ruby versions (rbenv) --"
    while IFS= read -r -d '' vdir; do
      v=$(basename "$vdir")
      if [[ "$v" == "$RBENV_GLOBAL" ]]; then
        log "  Skipping $v (matches global rbenv version)"
        continue
      fi
      quarantine_version_dir "rbenv" "$vdir" "$v"
    done < <(find "$REAL_HOME/.rbenv/versions" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi
fi

for conda_dir in "$REAL_HOME/miniconda3" "$REAL_HOME/anaconda3" "$REAL_HOME/.conda"; do
  if [[ -d "$conda_dir" ]]; then
    log "$(basename "$conda_dir"):"
    du -sh "$conda_dir" 2>/dev/null | tee -a "$LOG_FILE"
  fi
done

# --- Manually-placed binaries (not managed by Homebrew) ---
log "\n-- Binaries in /usr/local/bin and ~/.local/bin NOT managed by Homebrew --"
log "(these likely came from 'curl | bash' installers, manual downloads, or 'make install')"
if [[ $IS_TAHOE -eq 1 && "$ARCH" == "x86_64" ]]; then
  log "NOTE: On Intel Macs, macOS 26 Tahoe may have already emptied /usr/local during"
  log "an OS update. An empty /usr/local/bin here may mean tools were relocated to"
  log "/Users/Shared/Relocated Items — check there before assuming it was clean."
fi
MANUAL_BIN_CANDIDATES=()
for bindir in /usr/local/bin "$REAL_HOME/.local/bin"; do
  [[ -d "$bindir" ]] || continue
  for f in "$bindir"/*; do
    [[ -e "$f" ]] || continue
    if [[ -L "$f" ]]; then
      target=$(readlink "$f")
      case "$target" in *Cellar*|*homebrew*|*Caskroom*) continue ;; esac
    fi
    echo "$f" | tee -a "$LOG_FILE"
    MANUAL_BIN_CANDIDATES+=("$f")
  done
done

if [[ $INTERACTIVE_CLEANUP -eq 1 && ${#MANUAL_BIN_CANDIDATES[@]} -gt 0 ]]; then
  log "\n-- Interactive review: manually-placed binaries above --"
  mkdir -p "$LOG_DIR/quarantined-bin"
  for f in "${MANUAL_BIN_CANDIDATES[@]}"; do
    if confirm "  Quarantine '$f' (moves it to $LOG_DIR/quarantined-bin/, not deleted — restore by moving it back)?"; then
      mv "$f" "$LOG_DIR/quarantined-bin/" 2>/dev/null \
        && log "Moved $f to $LOG_DIR/quarantined-bin/"
    fi
  done
elif [[ ${#MANUAL_BIN_CANDIDATES[@]} -gt 0 && $CRON -eq 0 ]]; then
  log "\n(Use --apply --aggressive, outside of --cron, to quarantine these — recoverable, not deleted.)"
fi

# --- Shell configuration audit ---
log "\n-- Shell config audit --"
log "  Stale entries found will be listed. With --apply, you will be offered"
log "  the option to auto-comment them out. A .bak backup is made first."
log "  Always open a NEW terminal tab after any edit to verify your shell works."

for rc in "$REAL_HOME/.zshrc" "$REAL_HOME/.zprofile" "$REAL_HOME/.bash_profile" "$REAL_HOME/.bashrc" "$REAL_HOME/.profile"; do
  [[ -f "$rc" ]] || continue
  log "\n  $rc:"
  STALE_LINES=()

  # PATH entries pointing to non-existent directories
  while read -r dir; do
    dir="${dir//\$HOME/$REAL_HOME}"
    dir="${dir/#\~/$REAL_HOME}"
    # shellcheck disable=SC2016
    [[ -z "$dir" || "$dir" == '$PATH' || "$dir" == "PATH" ]] && continue
    if [[ ! -d "$dir" ]]; then
      # Find the actual line number(s) in the file
      while IFS= read -r lineno; do
        log "    [stale PATH] line $lineno: $dir (directory does not exist)"
        STALE_LINES+=("$lineno")
      done < <(grep -n "$dir" "$rc" 2>/dev/null | cut -d: -f1)
    fi
  done < <(grep -oE 'PATH=[^ ]*' "$rc" 2>/dev/null \
            | sed -E 's/^[A-Za-z_]+PATH=//; s/["\x27]//g' \
            | tr ':' '\n' | grep -E '^[~$/]' | sort -u)

  # Sourced files that don't exist
  while read -r srcfile; do
    srcfile_expanded="${srcfile//\$HOME/$REAL_HOME}"
    srcfile_expanded="${srcfile_expanded/#\~/$REAL_HOME}"
    [[ -z "$srcfile_expanded" ]] && continue
    if [[ ! -e "$srcfile_expanded" ]]; then
      while IFS= read -r lineno; do
        log "    [stale source] line $lineno: $srcfile (file does not exist)"
        STALE_LINES+=("$lineno")
      done < <(grep -n "$srcfile" "$rc" 2>/dev/null | cut -d: -f1)
    fi
  done < <(grep -oE '(^|[^.])\s(source|\.)\s+["\x27]?[^ "\x27]+' "$rc" 2>/dev/null \
            | awk '{print $NF}' | sed 's/["\x27]//g' | sort -u)

  # Aliases pointing to a missing command
  while IFS='=' read -r aliasname aliascmd; do
    aliasname=$(echo "$aliasname" | sed -E 's/^\s*alias\s+//')
    firstword=$(echo "$aliascmd" | sed -E "s/^['\"]//" | awk '{print $1}')
    [[ -z "$firstword" ]] && continue
    case "$firstword" in /*) [[ -x "$firstword" ]] && continue ;; esac
    if ! command -v "$firstword" &>/dev/null; then
      while IFS= read -r lineno; do
        log "    [broken alias] line $lineno: $aliasname → $aliascmd (command '$firstword' not found)"
        STALE_LINES+=("$lineno")
      done < <(grep -n "alias $aliasname" "$rc" 2>/dev/null | cut -d: -f1)
    fi
  done < <(grep -E '^\s*alias\s' "$rc" 2>/dev/null)

  # Offer to auto-comment stale lines if any found
  if [[ ${#STALE_LINES[@]} -gt 0 && $APPLY -eq 1 && $CRON -eq 0 ]]; then
    # Deduplicate line numbers
    mapfile -t UNIQUE_LINES < <(printf '%s\n' "${STALE_LINES[@]}" | sort -un)
    log "\n    Found ${#UNIQUE_LINES[@]} stale line(s) in $rc."
    if confirm "    Auto-comment out these lines in $rc? (backup saved as ${rc}.bak first)"; then
      cp "$rc" "${rc}.bak" && log "    Backup saved: ${rc}.bak"
      for lineno in "${UNIQUE_LINES[@]}"; do
        # Prefix the line with # if not already commented
        sed -i '' "${lineno}s/^[^#]/# &/" "$rc" 2>/dev/null \
          && log "    Commented out line $lineno in $rc"
      done
      log "    Done. Open a NEW terminal tab now to verify your shell loads cleanly."
    fi
  elif [[ ${#STALE_LINES[@]} -eq 0 ]]; then
    log "    (no stale entries found)"
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Summary + macOS notification (cron mode)
# ---------------------------------------------------------------------------
section "Summary"
log "Mode used: $([[ $APPLY -eq 1 ]] && echo APPLY || echo DRY-RUN)"
log "Full details written to: $LOG_FILE"
log ""

if [[ $CRON -eq 1 ]]; then
  # Count actual actions from log
  ACTIONS_TAKEN=$(grep -c '^\[ACTION\]' "$LOG_FILE" 2>/dev/null || echo 0)
  if [[ "$ACTIONS_TAKEN" -gt 0 ]]; then
    NOTIF_MSG="$ACTIONS_TAKEN item(s) cleaned. See ~/Library/Logs/macos-declutter/ for details."
  else
    NOTIF_MSG="Nothing to clean — Mac is already tidy."
  fi
  # Send macOS notification via osascript (works without terminal-notifier)
  run_as_user osascript -e "display notification \"$NOTIF_MSG\" with title \"Mac Declutter\" subtitle \"Biweekly cleanup complete\""  2>/dev/null || true
  log "Cron run complete. Actions taken: $ACTIONS_TAKEN. Notification sent."
else
  log "Two-step workflow:"
  log "  1. DRY-RUN (no flags): read the full report, understand what will be touched."
  log "  2. --apply: performs all safe steps AND prompts you interactively for:"
  log "       • Orphaned launch agents/daemons (binary missing — unambiguous waste)"
  log "       • Stale shell config entries (.zshrc etc.) with auto-comment + backup"
  log "       • Homebrew update/cleanup/autoremove, cache/log/Trash cleanup"
  log "       • npm cache clear"
  log "  3. --apply --aggressive: everything above PLUS item-by-item review of:"
  log "       • Unused apps (moved to Trash, recoverable)"
  log "       • Homebrew leaves"
  log "       • pip/npm/gem packages (user-installed only — default gems excluded)"
  log "       • cargo/go binaries, old nvm/pyenv/rbenv versions"
  log "       • Manual binaries in /usr/local/bin (quarantined, not deleted)"
  log ""
  log "  Quarantined/backed-up items live in: $LOG_DIR/"
  log "  Nothing is permanently deleted without you seeing it first."
fi

if [[ $JSON -eq 1 ]]; then
  ACTIONS_TAKEN=$(grep -c '^\[ACTION\]' "$LOG_FILE" 2>/dev/null || echo 0)
  RESTART_REQ=false
  { [[ -f /var/db/.SoftwareUpdateRequireRestart ]] || [[ -f /var/run/com.apple.SoftwareUpdate.requireRestart ]]; } && RESTART_REQ=true
  printf '{"tool":"twdxos","platform":"macos","script":"declutter","mode":"%s","aggressive":%s,"os_updates":%s,"actions_taken":%s,"restart_required":%s,"log_file":"%s","timestamp":"%s"}\n' \
    "$([[ $APPLY -eq 1 ]] && echo apply || echo dry-run)" \
    "$([[ $AGGRESSIVE -eq 1 ]] && echo true || echo false)" \
    "$([[ $OS_UPDATES -eq 1 ]] && echo true || echo false)" \
    "${ACTIONS_TAKEN:-0}" "$RESTART_REQ" "$LOG_FILE" \
    "$(date -Iseconds 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" >&3
fi
