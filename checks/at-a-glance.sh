#!/usr/bin/env bash
# at-a-glance.sh — LLM-generated anomaly summary of the main report
#
# Reads:   the HTML-stripped main report on stdin
# Output:  "✅ All clear" on clean days, or 3–5 bullets on anomaly days,
#          or "⚠️ Summary unavailable (<reason>)" on failure
# Test:    echo "Uptime: 3d, Disk /: 40%, Failed units: 0" \
#            | sudo bash checks/at-a-glance.sh
# Always exits 0 — never aborts the report.
#
# Uses the always-on CPU Ollama endpoint at localhost:11435 (independent of
# llm-mode). Model: qwen3-coder:30b. See ../CLAUDE.md "LLM dependency" section.

set -uo pipefail

ENDPOINT="http://localhost:11435/api/chat"
MODEL="qwen3-coder:30b"
# Empirically on this host (M720Q CPU, qwen3-coder:30b MoE, ~1400-token input):
# cold-load ~13s + prefill ~165s + generation ~15s ≈ 190s wall time.
# Prefill dominates on CPU. 240s gives headroom for a slow cold-load day.
MAX_TIME=240

read -r -d '' SYSTEM_PROMPT <<'EOF' || true
Your task: summarise a pre-tagged homelab status report.

The report wraps each value line with a status cue. Anomalies that the report's own checks have flagged end with the character ⚠. You do NOT decide what is an anomaly — the checks already did. Your only job is to surface every ⚠-tagged line as a bullet, or confirm there are no ⚠ markers.

RULES (follow in order):
1. Read the <REPORT> block in the user message.
2. Find every line that ends with the ⚠ character. These, and ONLY these, are anomalies.
3. If no line in the REPORT ends with ⚠: output the single line `✅ All clear` and stop. No period, no explanation, no extra whitespace.
4. Otherwise output one bullet per ⚠-tagged line, sorted by severity (security > data-loss > ops), max 5 bullets, each starting with `• ` (bullet + space). Plain text only. No HTML, no markdown, no preamble, no closing remark.
5. Each bullet paraphrases the ⚠-tagged line. Copy key numbers and names verbatim from that line. Do NOT add facts that are not in the REPORT.
6. Each bullet ≤ 120 characters.

BOUNDARIES (never flag these, even if they look concerning):
- Any line that does NOT end with ⚠.
- A `Docker: X/Y up` line followed by a `stopped: <id>` line when the report did not append ⚠ — this is a known persistent state, not an anomaly.
- Zero-count indicators anywhere (`0 failures`, `0 banned`, `0 infected`, `no warnings`, `all clear`).
- Disk, memory, or uptime values not marked with ⚠.
- Login counts from RFC1918 IPs.

GROUNDING:
- If a date, number, file name, service name, or phrase is not in the REPORT, it does not exist. Do not infer it, do not invent it.
- If you cannot point to a specific ⚠ character on a specific line, you have no anomaly — output `✅ All clear`.
- When in doubt, output `✅ All clear`. Silence is always safer than a fabricated bullet.

<EXAMPLE_DIRTY>
<INPUT>
  AIDE:      <date> <time> · <N> added · <N> changed · <N> removed ⚠
  ClamAV:    <date> · <N> files · 0 infected
  rkhunter:  <date> · <N> warning(s) ⚠
  SSH auth:  last 24h · 0 failure(s)
  fail2ban:  2 jail(s) · <N> banned ⚠
  Docker:    30/31 up
             stopped: <uuid>
  Backup:    <date> <time> · ✓
</INPUT>
<OUTPUT>
• AIDE: <N> added · <N> changed · <N> removed
• rkhunter: <N> warning(s)
• fail2ban: <N> IP(s) banned
</OUTPUT>
</EXAMPLE_DIRTY>

<EXAMPLE_CLEAN>
<INPUT>
  AIDE:      <date> <time> · 0 added · 0 changed · 0 removed
  ClamAV:    <date> · <N> files · 0 infected
  rkhunter:  <date> · all clear
  SSH auth:  last 24h · 0 failure(s)
  fail2ban:  2 jail(s) · 0 banned
  Docker:    30/31 up
             stopped: <uuid>
  Backup:    <date> <time> · ✓
</INPUT>
<OUTPUT>
✅ All clear
</OUTPUT>
</EXAMPLE_CLEAN>

Remember the core rule in different words: no ⚠ on a line = not an anomaly. No ⚠ in the whole REPORT = output literally `✅ All clear` and nothing else.
EOF

# Read the report from stdin
REPORT=$(cat)

if [[ -z "$REPORT" ]]; then
  echo "⚠️ Summary unavailable (empty input)"
  exit 0
fi

# Build the JSON body with python3 (stdlib — no new deps). json.dumps handles
# all quoting/escaping of newlines, quotes, backslashes, and unicode.
BODY=$(SYSTEM="$SYSTEM_PROMPT" USER_REPORT="$REPORT" MODEL="$MODEL" python3 <<'PY'
import json, os
user_content = "<REPORT>\n" + os.environ["USER_REPORT"].rstrip() + "\n</REPORT>"
body = {
    "model":    os.environ["MODEL"],
    "stream":   False,
    "keep_alive": 0,
    "messages": [
        {"role": "system", "content": os.environ["SYSTEM"]},
        {"role": "user",   "content": user_content},
    ],
    "options": {
        "num_ctx":     8192,
        "num_predict": 200,
        "temperature": 0.2,
    },
}
print(json.dumps(body))
PY
) || { echo "⚠️ Summary unavailable (body build failed)"; exit 0; }

# Call the CPU LLM. --max-time caps total latency so we never block the report.
RESPONSE=$(curl -s --max-time "$MAX_TIME" \
  -H "Content-Type: application/json" \
  -d "$BODY" \
  "$ENDPOINT")
CURL_RC=$?

if [[ $CURL_RC -ne 0 ]]; then
  # 28 = operation timeout, 7 = connection refused, others = network/transport
  case $CURL_RC in
    28) echo "⚠️ Summary unavailable (LLM timeout after ${MAX_TIME}s)";;
    7)  echo "⚠️ Summary unavailable (LLM unreachable — is Ollama running?)";;
    *)  echo "⚠️ Summary unavailable (curl error ${CURL_RC})";;
  esac
  exit 0
fi

# Extract .message.content from the chat-endpoint response.
CONTENT=$(RESP="$RESPONSE" python3 <<'PY'
import json, os, sys
try:
    d = json.loads(os.environ["RESP"])
except Exception as e:
    print("", end="")
    sys.exit(0)
msg = (d.get("message") or {}).get("content") or ""
print(msg, end="")
PY
)

# Trim leading/trailing whitespace
CONTENT="${CONTENT#"${CONTENT%%[![:space:]]*}"}"
CONTENT="${CONTENT%"${CONTENT##*[![:space:]]}"}"

if [[ -z "$CONTENT" ]]; then
  echo "⚠️ Summary unavailable (empty response)"
  exit 0
fi

echo "$CONTENT"
exit 0
