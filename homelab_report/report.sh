#!/usr/bin/env bash
# report.sh — Homelab daily Telegram report
#
# Assembles a single daily status message from all check scripts and sends
# it to a Telegram chat via the Bot API. Designed to be run as root by
# the tg-homelab-report.timer systemd timer at 12:00 every day.
#
# Usage:
#   sudo bash /srv/services/tg/homelab_report/report.sh
#
# Requires:
#   .env in the same directory as this script with:
#     TG_BOT_TOKEN=<bot token from @BotFather>
#     TG_CHAT_ID=<your chat ID>
#   curl (always available on Debian)
#
# Each check script in checks/ is called in a subshell. If a check fails
# for any reason its output will be empty and it's silently skipped —
# this ensures one broken check never stops the whole report.
#
# The message body is wrapped in <pre>...</pre> and sent with parse_mode=HTML
# so Telegram renders it in a monospace font, keeping columns aligned.
#
# See CLAUDE.md for full architecture, debugging, and how to add new checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Load credentials ──────────────────────────────────────────────────────────

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Copy .env.example to .env and fill in values." >&2
  exit 1
fi

# shellcheck source=.env
source "$ENV_FILE"

if [[ -z "${TG_BOT_TOKEN:-}" || "$TG_BOT_TOKEN" == "REPLACE_ME" ]]; then
  echo "ERROR: TG_BOT_TOKEN not set in ${ENV_FILE}" >&2
  exit 1
fi
if [[ -z "${TG_CHAT_ID:-}" || "$TG_CHAT_ID" == "REPLACE_ME" ]]; then
  echo "ERROR: TG_CHAT_ID not set in ${ENV_FILE}" >&2
  exit 1
fi

# ── AIDE attachment ───────────────────────────────────────────────────────────

# Sends a trimmed AIDE diff as a file attachment after the main message.
# Only fires when there are changes beyond the expected daily baseline
# (audit.log and wtmp.db are filtered out as known-changing files).
send_aide_attachment() {
  local log="/var/log/aide/aide-$(date +%Y-%m-%d).log"
  [[ -f "$log" && -s "$log" ]] || log="/var/log/aide/aide.log"
  [[ -f "$log" && -s "$log" ]] || return 0

  local diff
  diff=$(awk '/^(Added|Removed|Changed) entries:/{found=1} found{print}' "$log" \
    | grep -v '/var/log/audit/audit\.log\|/var/log/wtmp\.db' \
    || true)

  # Skip if only section headers and separators remain
  local meaningful
  meaningful=$(echo "$diff" \
    | grep -vE '^(Added|Removed|Changed) entries:|^-{10,}|^[[:space:]]*$' \
    || true)
  [[ -z "$meaningful" ]] && return 0

  local tmpfile
  tmpfile=$(mktemp /tmp/aide-diff-XXXXXX.log)
  echo "$diff" > "$tmpfile"

  curl -s -o /dev/null \
    -F "chat_id=${TG_CHAT_ID}" \
    -F "document=@${tmpfile}" \
    -F "caption=AIDE diff — $(date '+%Y-%m-%d %H:%M')" \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" || true

  rm -f "$tmpfile"
}

# ── Run checks ────────────────────────────────────────────────────────────────

# Helper: run a check script, capture output, never fail.
# HTML-escapes output so <pre> rendering is safe.
run_check() {
  local script="${SCRIPT_DIR}/checks/${1}"
  if [[ ! -x "$script" ]]; then
    echo "  [${1}: script not found or not executable]"
    return 0
  fi
  local out
  out=$(bash "$script" 2>/dev/null) || out="  [${1}: error — check log for details]"
  # Escape HTML special characters so they render literally inside <pre>
  echo "$out" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

DATE=$(date +%Y-%m-%d)
TIME=$(date +%H:%M)

AIDE=$(run_check aide.sh)
CLAMAV=$(run_check clamav.sh)
RKHUNTER=$(run_check rkhunter.sh)
AUTH=$(run_check auth.sh)
FAIL2BAN=$(run_check fail2ban.sh)

DISK=$(run_check disk.sh)
SYSTEM=$(run_check system.sh)
MEMORY=$(run_check memory.sh)
SMART=$(run_check smart.sh)
DOCKER=$(run_check docker.sh)
LOGINS=$(run_check logins.sh)
SYSTEMD_FAILED=$(run_check systemd.sh)

BACKUP=$(run_check backup.sh)

# ── Assemble message ──────────────────────────────────────────────────────────

# Build Security section; omit fail2ban line if not installed (empty output)
SECURITY_SECTION="${AIDE}
${CLAMAV}
${RKHUNTER}
${AUTH}"
if [[ -n "$FAIL2BAN" ]]; then
  SECURITY_SECTION="${SECURITY_SECTION}
${FAIL2BAN}"
fi

# Build the System section; omit the Systemd line if there are no failures
SYSTEM_SECTION="${SYSTEM}
${MEMORY}
${SMART}
${DOCKER}
${LOGINS}"
if [[ -n "$SYSTEMD_FAILED" ]]; then
  SYSTEM_SECTION="${SYSTEM_SECTION}
${SYSTEMD_FAILED}"
fi

# The body is wrapped in <pre>...</pre> for monospace rendering in Telegram.
# Emoji section headers are outside <pre> to render at full size.
MSG="🏠 Homelab Report — ${DATE} ${TIME}

🛡 Security
<pre>${SECURITY_SECTION}</pre>

💾 Disk  [checked ${TIME}]
<pre>${DISK}</pre>

🖥 System  [checked ${TIME}]
<pre>${SYSTEM_SECTION}</pre>

🗄 Backups
<pre>${BACKUP}</pre>"

# ── Send via Telegram Bot API ─────────────────────────────────────────────────

# parse_mode=HTML enables <pre> monospace blocks.
# --data-urlencode safely handles any characters in the message text.
# -o /dev/null suppresses response body; -w shows HTTP status for logging.
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --data-urlencode "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "text=${MSG}" \
  --data-urlencode "parse_mode=HTML" \
  "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage") || {
  echo "WARNING: curl failed to reach Telegram API" >&2
  exit 0
}

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "WARNING: Telegram API returned HTTP ${HTTP_STATUS}" >&2
fi

send_aide_attachment

# Always exit 0 — a failed send should not be treated as a systemd unit failure
exit 0
