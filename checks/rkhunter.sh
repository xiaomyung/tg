#!/usr/bin/env bash
# rkhunter.sh — Rootkit Hunter daily check summary
#
# Reads:   /var/log/rkhunter.log
# Output:  "  rkhunter:  YYYY-MM-DD · all clear"
#          "  rkhunter:  YYYY-MM-DD · N warning(s) ⚠"
# Format:  printf "  %-9s  %s\n"  (values start at column 13)
# Test:    sudo bash checks/rkhunter.sh
# Always exits 0.

set -euo pipefail

LOG="/var/log/rkhunter.log"

if [[ ! -f "$LOG" ]]; then
  printf "  %-9s  no log found\n" "rkhunter:"
  exit 0
fi

MTIME=$(stat -c %Y "$LOG")
AGE_DAYS=$(( ($(date +%s) - MTIME) / 86400 ))
SCAN_DATE=$(date -d "@$MTIME" +%Y-%m-%d)

if [[ $AGE_DAYS -gt 2 ]]; then
  printf "  %-9s  no recent run (last: %s, %dd ago) ⚠\n" "rkhunter:" "$SCAN_DATE" "$AGE_DAYS"
  exit 0
fi

# [ Warning ] is rkhunter's single marker for ALL problems — suspicious files,
# rootkit signatures, infected binaries, config issues. Everything bad is a warning.
WARNING_COUNT=$(grep -c '\[ Warning \]' "$LOG" 2>/dev/null || true)
WARNING_COUNT=${WARNING_COUNT:-0}

if [[ "$WARNING_COUNT" -eq 0 ]]; then
  VALUE="${SCAN_DATE} · all clear"
else
  VALUE="${SCAN_DATE} · ${WARNING_COUNT} warning(s) ⚠"
fi

printf "  %-9s  %s\n" "rkhunter:" "$VALUE"
