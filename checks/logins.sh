#!/usr/bin/env bash
# logins.sh — Successful SSH/console logins in the last 24 hours
#
# Reads:   /var/log/wtmp via `last`
# Output:  "  Logins:    none in last 24h"
#          "  Logins:    2 in last 24h"
#          "             apollo from 192.168.1.10 at 03-28 10:30"
#          "             root at 03-27 22:15 (local)"
# Format:  printf "  %-8s   %s\n" for the count line;
#          13-space indent for each login entry.
#
# Uses a rolling 24-hour window so cross-midnight sessions are counted
# by their actual login time, not by calendar day.
#
# last --time-format iso field layout:
#   With source IP:  user  tty  source  login-time  [- logout-time (dur)]
#   Without source:  user  tty  login-time  [- logout-time (dur)]
# Detected by checking whether field 3 contains 'T' (ISO timestamp marker).
#
# Test:    bash checks/logins.sh
# Always exits 0 — never aborts the report.

set -euo pipefail

CUTOFF=$(date -d '24 hours ago' +%s)
# 13 spaces — aligns under value column (2 + 8 label + 3 sep)
INDENT="             "

# Parse a last --time-format iso line; sets USER, SOURCE, TS.
# SOURCE is empty string for local/no-source logins.
parse_line() {
  local line="$1"
  USER=$(echo "$line" | awk '{print $1}')
  local f3
  f3=$(echo "$line" | awk '{print $3}')
  # If field 3 contains 'T' it is an ISO timestamp → no source IP in this entry
  if [[ "$f3" == *T* ]]; then
    SOURCE=""
    TS="$f3"
  else
    SOURCE="$f3"
    TS=$(echo "$line" | awk '{print $4}')
  fi
}

TODAYS=$(last --time-format iso 2>/dev/null \
  | grep -vE "^reboot|^wtmp" \
  | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      parse_line "$line"
      # Skip if TS doesn't look like an ISO timestamp (guards against '-' separator)
      [[ "$TS" == *T* ]] || continue
      TS_EPOCH=$(date -d "$TS" +%s 2>/dev/null) || continue
      [[ "$TS_EPOCH" -ge "$CUTOFF" ]] && echo "$line"
    done \
  || true)

COUNT=$(echo "$TODAYS" | grep -c "[a-z]" || true)
COUNT=${COUNT:-0}

if [[ "$COUNT" -eq 0 ]]; then
  printf "  %-8s   %s\n" "Logins:" "none in last 24h"
  exit 0
fi

printf "  %-8s   %s\n" "Logins:" "${COUNT} in last 24h"

declare -A counts
declare -A latest
declare -a order

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  parse_line "$line"
  DATE=$(date -d "$TS" '+%m-%d' 2>/dev/null || echo "?")
  TIME=$(date -d "$TS" '+%H:%M' 2>/dev/null || echo "?")
  KEY="${USER}|${SOURCE}|${DATE}"
  if [[ -z "${counts[$KEY]+x}" ]]; then
    order+=("$KEY")
    counts[$KEY]=0
    latest[$KEY]="$TIME"
  fi
  counts[$KEY]=$(( counts[$KEY] + 1 ))
done <<< "$TODAYS"

mapfile -t sorted_keys < <(
  for KEY in "${order[@]}"; do
    IFS='|' read -r u src dt <<< "$KEY"
    echo "${counts[$KEY]}|${dt}|${KEY}"
  done | sort -t'|' -k1,1rn -k2,2r | awk -F'|' '{print $3"|"$4"|"$5}'
)

for KEY in "${sorted_keys[@]}"; do
  IFS='|' read -r u src dt <<< "$KEY"
  CNT=${counts[$KEY]}
  LT=${latest[$KEY]}
  if [[ -z "$src" ]]; then
    printf "%s%s at %s, last %s, (%s) (local)\n"   "$INDENT" "$u" "$dt" "$LT" "$CNT"
  elif [[ "$src" =~ ^(:[0-9]|tty|pts) ]]; then
    printf "%s%s at %s, last %s, (%s) (console)\n" "$INDENT" "$u" "$dt" "$LT" "$CNT"
  else
    printf "%s%s from %s at %s, last %s, (%s)\n"   "$INDENT" "$u" "$src" "$dt" "$LT" "$CNT"
  fi
done
