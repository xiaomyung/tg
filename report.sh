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

# ── Helpers ───────────────────────────────────────────────────────────────────

# Escape the three HTML entities Telegram's <pre> block interprets literally.
# Reads stdin, writes stdout.
html_escape() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# ── AIDE attachment ───────────────────────────────────────────────────────────

# Sends a trimmed AIDE diff as a file attachment, as a reply to the main message.
# Only fires when there are changes beyond the expected daily baseline
# (audit.log and wtmp.db are filtered out as known-changing files).
# Args: $1 — message_id to reply to (optional; omit to send without threading)
send_aide_attachment() {
  local reply_to_id="${1:-}"
  local log="/var/log/aide/aide-$(date +%Y-%m-%d).log"
  [[ -f "$log" && -s "$log" ]] || log="/var/log/aide/aide.log"
  [[ -f "$log" && -s "$log" ]] || return 0

  # Extract diff sections, filtering out expected daily-baseline files
  # (audit.log, wtmp.db) including their detail blocks.
  local aide_diff
  aide_diff=$(awk '
    BEGIN {
      exclude["/var/log/audit/audit.log"] = 1
      exclude["/var/log/wtmp.db"] = 1
    }
    /^(Added|Removed|Changed) entries:/ { in_entries = 1; in_detail = 0; skip_block = 0 }
    !in_entries { next }

    # Summary lines: "f >b... : /path" — check if path is excluded
    /^[[:space:]]*[a-z].*: \// {
      path = $NF
      if (path in exclude) next
      print; next
    }

    # Start of detailed section
    /^Detailed information about changes:/ {
      in_detail = 1; skip_block = 0
      detail_hdr = $0; next
    }

    # Separator lines — buffer in detail mode, print otherwise
    /^-{10,}$/ { if (in_detail) { pending_sep = $0; next } else { print; next } }

    # "File: /path" starts a new detail block
    /^File: / {
      if ($2 in exclude) { skip_block = 1 } else {
        skip_block = 0
        if (detail_hdr != "") { print ""; print detail_hdr; print "---------------------------------------------------"; detail_hdr = "" }
        if (pending_sep != "") { print pending_sep; pending_sep = "" }
        print
      }
      next
    }

    # Attribute lines inside a detail block
    in_detail { if (!skip_block) print; next }

    # Section headers, blank lines, other content
    { print }
  ' "$log" || true)

  # Skip if only section headers and separators remain
  local meaningful
  meaningful=$(echo "$aide_diff" \
    | grep -vE '^(Added|Removed|Changed) entries:|^Detailed information|^-{10,}|^[[:space:]]*$' \
    || true)
  [[ -z "$meaningful" ]] && return 0

  local tmpfile
  tmpfile=$(mktemp /tmp/aide-diff-XXXXXX.txt)
  chmod 600 "$tmpfile"
  echo "$aide_diff" > "$tmpfile"

  local extra_args=()
  [[ -n "$reply_to_id" ]] && extra_args+=(-F "reply_to_message_id=${reply_to_id}")

  local attach_resp attach_status
  attach_resp=$(curl -s -w "\n%{http_code}" \
    -F "chat_id=${TG_CHAT_ID}" \
    -F "document=@${tmpfile};type=text/plain" \
    -F "caption=AIDE diff — $(date '+%Y-%m-%d %H:%M')" \
    "${extra_args[@]}" \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument") || true
  attach_status=$(echo "$attach_resp" | tail -n1)
  if [[ "$attach_status" != "200" ]]; then
    echo "WARNING: AIDE attachment send returned HTTP ${attach_status}" >&2
  fi

  rm -f "$tmpfile"
}

# ── LLM "at a glance" summary ─────────────────────────────────────────────────

# Sends an LLM-generated anomaly summary as a reply to the main message.
# Uses the always-on CPU Ollama endpoint at localhost:11435 (independent of
# llm-mode). Summary script always exits 0 and returns either "✅ All clear",
# 3–5 bullet anomalies, or "⚠️ Summary unavailable (<reason>)".
# Args: $1 — message_id to reply to
#       $2 — HTML-stripped main message to feed the LLM
send_summary() {
  local reply_to_id="${1:-}"
  local plain_msg="${2:-}"
  [[ -n "$plain_msg" ]] || return 0

  local summary
  summary=$(printf '%s' "$plain_msg" | bash "${SCRIPT_DIR}/checks/at-a-glance.sh" 2>/dev/null) || return 0
  [[ -n "$summary" ]] || return 0

  # Escape HTML so <pre> rendering is safe (the LLM could emit characters
  # Telegram's HTML parser would otherwise swallow).
  local escaped
  escaped=$(printf '%s' "$summary" | html_escape)

  local text="🔎 At a glance
<pre>${escaped}</pre>"

  local extra_args=()
  [[ -n "$reply_to_id" ]] && extra_args+=(--data-urlencode "reply_to_message_id=${reply_to_id}")

  local resp status
  resp=$(curl -s -w "\n%{http_code}" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "parse_mode=HTML" \
    "${extra_args[@]}" \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage") || true
  status=$(echo "$resp" | tail -n1)
  if [[ "$status" != "200" ]]; then
    echo "WARNING: summary send returned HTTP ${status}" >&2
  fi
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
  echo "$out" | html_escape
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
# Capture full JSON response to extract message_id for reply threading.
RESPONSE=$(curl -s -w "\n%{http_code}" \
  --data-urlencode "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "text=${MSG}" \
  --data-urlencode "parse_mode=HTML" \
  "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage") || {
  echo "WARNING: curl failed to reach Telegram API" >&2
  exit 0
}

HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n-1)

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "WARNING: Telegram API returned HTTP ${HTTP_STATUS}" >&2
fi

# Extract message_id so the AIDE attachment is sent as a reply (visually linked)
MSG_ID=$(echo "$RESPONSE_BODY" | grep -o '"message_id":[0-9]*' | grep -o '[0-9]*' || true)

if [[ "$HTTP_STATUS" == "200" ]]; then
  # Strip HTML tags and decode the three entities run_check introduces, so the
  # LLM sees the same text a human would see rendered in Telegram.
  MSG_PLAIN=$(echo "$MSG" | sed -e 's/<[^>]*>//g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g')
  send_summary "$MSG_ID" "$MSG_PLAIN"
  send_aide_attachment "$MSG_ID"
fi

# Always exit 0 — a failed send should not be treated as a systemd unit failure
exit 0
