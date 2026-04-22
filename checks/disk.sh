#!/usr/bin/env bash
# disk.sh — Disk usage on key mount points
#
# Reads:   df -h (live)
# Output:  "  /path:          N% used (of SIZE)"
#          Append " ⚠" if usage >= 85%.
# Format:  printf "  %-13s  %s%s\n"  (values start at column 17)
#          /mnt/storage: is 13 chars — the longest path label.
# Test:    bash checks/disk.sh
# Always exits 0.

set -euo pipefail

CORE_PATHS=("/")
OPTIONAL_PATHS=("/mnt/storage" "/mnt/cloud")

check_path() {
  local path="$1"
  if ! mountpoint -q "$path" 2>/dev/null && [[ "$path" != "/" ]]; then
    return 0
  fi
  local info
  info=$(df -h "$path" 2>/dev/null | awk 'NR==2 {print $5, $2}') || return 0
  local pct="${info%% *}"
  local size="${info##* }"
  local pct_num="${pct%%%}"
  local label="${path}:"
  local value="${pct} used (of ${size})"
  local warn=""
  [[ "$pct_num" -ge 85 ]] && warn=" ⚠"
  printf "  %-13s  %s%s\n" "$label" "$value" "$warn"
}

for p in "${CORE_PATHS[@]}"; do check_path "$p"; done
for p in "${OPTIONAL_PATHS[@]}"; do check_path "$p"; done
