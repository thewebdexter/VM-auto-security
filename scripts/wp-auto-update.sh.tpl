#!/bin/bash
# wp-auto-update.sh
# Installed by wp-automaint — https://github.com/thewebdexter/VM-auto-security

WP_PATH="__WP_PATH__"
WP_USER="__WP_USER__"
LOG="__LOG_FILE__"

{
    echo ""
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="
    sudo -u "$WP_USER" wp --path="$WP_PATH" core update
    sudo -u "$WP_USER" wp --path="$WP_PATH" plugin update --all
    sudo -u "$WP_USER" wp --path="$WP_PATH" theme update --all
    sudo -u "$WP_USER" wp --path="$WP_PATH" core language update
    echo "=== done ==="
} >> "$LOG" 2>&1
