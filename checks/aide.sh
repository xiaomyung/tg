#!/usr/bin/env bash
# aide.sh — AIDE scan summary
#
# Reads:   /var/log/aide/aide-YYYY-MM-DD.log  (preferred — dated copy saved by aide-save-report hook)
#          /var/log/aide/aide.log              (fallback — if dated files aren't being created)
# Output:  "  AIDE:      YYYY-MM-DD HH:MM · N added · N changed · N removed"
#          Append " ⚠" if any changes found.
#          "  AIDE:      scan FAILED (exit code N) ⚠" if aide aborted before scanning.
# Format:  printf "  %-9s  %s%s\n"  (values start at column 13)
# Test:    sudo bash checks/aide.sh
# Always exits 0.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DATED_LOG="/var/log/aide/aide-$(date +%Y-%m-%d).log"
FALLBACK_LOG="/var/log/aide/aide.log"

if [[ -f "$DATED_LOG" && -s "$DATED_LOG" ]]; then
  LOG="$DATED_LOG"
elif [[ -f "$FALLBACK_LOG" && -s "$FALLBACK_LOG" ]]; then
  LOG="$FALLBACK_LOG"
  stale_guard "$LOG" 2 "AIDE:" || exit 0
else
  printf "  %-9s  no log found\n" "AIDE:"
  exit 0
fi

# A failed scan still produces a fresh log: dailyaidecheck writes an error
# report ("AIDE returned with exit code 18. Input/Output error!") that has no
# summary section — without this guard it parses as a clean 0/0/0 scan.
# Exit codes 1-7 are the added/removed/changed bitmask; anything above is an
# error, and "AIDE error output" only appears in error reports.
EXIT_CODE=$(grep -oP 'AIDE returned with exit code \K[0-9]+' "$LOG" | head -1 || true)
if grep -q '^AIDE error output' "$LOG" || { [[ -n "$EXIT_CODE" ]] && (( EXIT_CODE > 7 )); }; then
  printf "  %-9s  scan FAILED (exit code %s) ⚠\n" "AIDE:" "${EXIT_CODE:-?}"
  exit 0
fi

SCAN_TIME=$(head -1 "$LOG" | grep -oP '\d{4}-\d{2}-\d{2} \d{2}:\d{2}' || true)
[[ -z "$SCAN_TIME" ]] && SCAN_TIME=$(date -d "@$(stat -c %Y "$LOG")" +"%Y-%m-%d %H:%M")

ADDED=$(awk '/^  Added entries:/{print $NF}' "$LOG" | head -1); ADDED=${ADDED:-0}
REMOVED=$(awk '/^  Removed entries:/{print $NF}' "$LOG" | head -1); REMOVED=${REMOVED:-0}
CHANGED=$(awk '/^  Changed entries:/{print $NF}' "$LOG" | head -1); CHANGED=${CHANGED:-0}

VALUE="${SCAN_TIME} · ${ADDED} added · ${CHANGED} changed · ${REMOVED} removed"
WARN=""
[[ "$ADDED" != "0" || "$CHANGED" != "0" || "$REMOVED" != "0" ]] && WARN=" ⚠"

printf "  %-9s  %s%s\n" "AIDE:" "$VALUE" "$WARN"
