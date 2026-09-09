#!/bin/bash
# wp-auto-update.sh
# Installed by TWDxOSOptimisation (macOS, optional WP-CLI module)
# https://github.com/TheWebDexterTech/TWDxOSOptimisation
#
# Idempotent WordPress maintenance: core, plugin, theme, language updates,
# cache flush, transient sweep, and DB optimize. Logs every step. Exits with
# the number of failed steps.
#
# Intended for local WordPress dev on macOS (e.g. via MAMP/Herd) — this is
# not the centerpiece of the macOS platform (see declutter.sh for that).
# Run it manually, or wrap it in your own launchd job; install.sh does not
# schedule this automatically.

set -uo pipefail

WP_PATH="__WP_PATH__"
WP_USER="__WP_USER__"
LOG="__LOG_FILE__"
# Per-user lock in the caller's private temp dir — never a predictable path in
# shared /tmp (symlink-follow risk on multi-user Macs).
LOCK="${TMPDIR:-/tmp}/twdxos-wp-auto-update.$(id -u).lock"

# Single-instance guard: silently skip if another run is in progress.
exec 9>"$LOCK"
if ! flock -n 9 2>/dev/null; then
    echo "[$(date -Iseconds)] skip: another wp-auto-update is running" >> "$LOG"
    exit 0
fi

failures=0
run() {
    local label="$1"; shift
    echo "[$(date -Iseconds)] -> $label" >> "$LOG"
    if "$@" >> "$LOG" 2>&1; then
        echo "[$(date -Iseconds)] ok   $label" >> "$LOG"
    else
        echo "[$(date -Iseconds)] FAIL $label (exit $?)" >> "$LOG"
        failures=$((failures + 1))
    fi
}

if [[ "$(whoami)" == "$WP_USER" ]]; then
    WP=(wp --path="$WP_PATH")
else
    WP=(sudo -u "$WP_USER" wp --path="$WP_PATH")
fi

{
    echo ""
    echo "=== $(date -Iseconds) START ==="
} >> "$LOG"

run "core update"          "${WP[@]}" core update
run "core update-db"       "${WP[@]}" core update-db
run "plugin update --all"  "${WP[@]}" plugin update --all
run "theme update --all"   "${WP[@]}" theme update --all
run "core language update" "${WP[@]}" core language update
run "cache flush"          "${WP[@]}" cache flush
run "transient delete"     "${WP[@]}" transient delete --all
run "db optimize"          "${WP[@]}" db optimize

echo "=== $(date -Iseconds) DONE (failures: $failures) ===" >> "$LOG"
exit "$failures"
