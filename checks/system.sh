#!/usr/bin/env bash
# system.sh — System health: uptime, pending reboot, security updates
#
# Output (one line each, omitting lines that are all-clear where noted):
#   "  Uptime:    N days, N hours"
#   "  Reboot:    not required"       or   "  Reboot:    required (pkg1, pkg2) ⚠"
#   "  Updates:   N security update(s) pending ⚠"  (line omitted if 0 pending)
#
# Pending reboot: Debian/Ubuntu create /var/run/reboot-required after installing
# a kernel or library that requires a reboot to take effect.
#
# Security updates: apt list --upgradable filtered for packages from security repos.
# Note: apt may print a WARNING about using unstable CLI; we suppress that on stderr.
#
# Test:    sudo bash checks/system.sh
# Always exits 0 — never aborts the report.

set -euo pipefail

# ── Uptime ──
UPTIME=$(uptime -p 2>/dev/null | sed 's/^up //')
printf "  %-8s   %s\n" "Uptime:" "$UPTIME"

# ── Pending reboot ──
if [[ -f /var/run/reboot-required ]]; then
  REASON=""
  if [[ -f /var/run/reboot-required.pkgs ]]; then
    PKGS=$(head -3 /var/run/reboot-required.pkgs | paste -sd ', ')
    REASON=" (${PKGS})"
  fi
  printf "  %-8s   %s %s\n" "Reboot:" "required${REASON}" "⚠"
else
  printf "  %-8s   %s\n" "Reboot:" "not required"
fi

# ── Security updates ──
# apt list --upgradable 2>/dev/null suppresses the "WARNING: apt..." CLI warning.
# We filter lines containing '/.*-security' or '/.*security' in the apt source field.
SEC_COUNT=$(apt list --upgradable 2>/dev/null | grep -cE '/[^/]*security' || true)
SEC_COUNT=${SEC_COUNT:-0}

if [[ "$SEC_COUNT" -gt 0 ]]; then
  printf "  %-8s   %s %s\n" "Updates:" "${SEC_COUNT} security update(s) pending" "⚠"
fi
# If 0, print nothing — no news is good news
