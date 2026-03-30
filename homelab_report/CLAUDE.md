# homelab_report — CLAUDE.md

Daily Telegram report for the homelab. Sends one message at noon covering
security tool results, disk usage, system health, and backup status.

---

## Architecture

```
/srv/services/tg/homelab_report/
├── CLAUDE.md           ← you are here
├── .env                ← credentials (TG_BOT_TOKEN, TG_CHAT_ID) — root:root 600
├── .env.example        ← template with instructions
├── report.sh           ← main script: runs all checks, assembles message, sends it
├── checks/
│   ├── aide.sh         ← reads /var/log/aide/aide-YYYY-MM-DD.log
│   ├── clamav.sh       ← reads /var/log/clamav/weekly-scan.log
│   ├── rkhunter.sh     ← reads /var/log/rkhunter.log
│   ├── disk.sh         ← df -h on /, /mnt/storage, /mnt/cloud
│   ├── docker.sh       ← docker ps -a
│   ├── smart.sh        ← smartctl -H on sda, sdb (sat), nvme0n1
│   ├── systemd.sh      ← systemctl --failed
│   ├── system.sh       ← uptime, /var/run/reboot-required, apt security updates
│   └── backup.sh       ← parses server-backup-cron.log + recovery-snapshot.log
```

**Data flow:**
1. systemd timer fires `tg-homelab-report.service` at 12:00 daily
2. `report.sh` runs as root, calls each `checks/*.sh` in a subshell
3. Each check prints its line(s) to stdout and exits 0
4. `report.sh` assembles all output into a single message
5. `curl` POSTs the message to the Telegram Bot API

---

## Scheduled execution

The report is sent by a systemd timer — no cron involved.

```
/etc/systemd/system/tg-homelab-report.timer    # fires daily at 12:00
/etc/systemd/system/tg-homelab-report.service  # runs report.sh as root
```

**Check timer status:**
```bash
systemctl status tg-homelab-report.timer
systemctl list-timers | grep tg-
```

**Check last run:**
```bash
journalctl -u tg-homelab-report.service -n 50
```

---

## Running manually

```bash
# Run the full report (sends a real Telegram message)
sudo bash /srv/services/tg/homelab_report/report.sh

# Run a single check to inspect its output
sudo bash /srv/services/tg/homelab_report/checks/aide.sh
sudo bash /srv/services/tg/homelab_report/checks/backup.sh
# etc.
```

---

## Credentials (.env)

```
TG_BOT_TOKEN=<bot token from @BotFather>
TG_CHAT_ID=<your numeric chat ID>
```

Permissions must be: `root:root`, mode `600`.
```bash
sudo chown root:root /srv/services/tg/homelab_report/.env
sudo chmod 600 /srv/services/tg/homelab_report/.env
```

**Getting your chat ID:**
1. Send any message to your bot
2. Call: `curl "https://api.telegram.org/bot<TOKEN>/getUpdates"`
3. Look for `"chat": {"id": 123456789}`

---

## Source logs for each check

| Check | Log / Command | Notes |
|-------|--------------|-------|
| aide.sh | `/var/log/aide/aide-YYYY-MM-DD.log` | Daily; hook saves dated copy |
| clamav.sh | `/var/log/clamav/weekly-scan.log` | Weekly; shows scan date explicitly |
| rkhunter.sh | `/var/log/rkhunter.log` | Daily; enabled via `/etc/default/rkhunter` |
| disk.sh | `df -h` live | /mnt/storage and /mnt/cloud skipped if unmounted |
| docker.sh | `docker ps -a` live | |
| smart.sh | `smartctl -H` live | sdb uses `-d sat` for USB bridge |
| systemd.sh | `systemctl --failed` live | Line omitted from report if no failures |
| system.sh | `uptime`, `/var/run/reboot-required`, `apt list` live | Security updates line omitted if 0 |
| backup.sh | `/var/log/server-backup-cron.log` + `/var/log/recovery-snapshot.log` | Runs at 04:00 / 04:30 |

---

## Debugging a failing check

1. **Run the check standalone** and inspect output:
   ```bash
   sudo bash /srv/services/tg/homelab_report/checks/foo.sh
   ```

2. **Check that the source log exists and has today's data:**
   ```bash
   ls -la /var/log/aide/aide-$(date +%Y-%m-%d).log
   tail -20 /var/log/server-backup-cron.log
   ```

3. **Check the systemd journal** for the last timer run:
   ```bash
   journalctl -u tg-homelab-report.service --since today
   ```

4. **Test Telegram connectivity:**
   ```bash
   source /srv/services/tg/homelab_report/.env
   curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getMe"
   ```

---

## Adding a new check

1. Create `checks/newcheck.sh` with this structure:
   ```bash
   #!/usr/bin/env bash
   # newcheck.sh — One-line description
   #
   # Reads:   <source log or command>
   # Output:  "  Label:    value"  or  "⚠️   Label:    problem"
   # Test:    sudo bash checks/newcheck.sh
   # Always exits 0 — never aborts the report.

   set -euo pipefail

   # ... your logic ...
   echo "  Label:    result"
   ```

2. `chmod +x checks/newcheck.sh`

3. In `report.sh`, add:
   ```bash
   NEWCHECK=$(run_check newcheck.sh)
   ```
   and include `${NEWCHECK}` in the `MSG` variable in the appropriate section.

---

## Time window convention

Checks that count events (logins, SSH auth failures) use a **rolling 24-hour
window**, not a calendar day. Implementation pattern:

```bash
CUTOFF=$(date -d '24 hours ago' +%s)
# For each entry: convert timestamp to epoch, skip if < CUTOFF
TS_EPOCH=$(date -d "$TS" +%s 2>/dev/null) || continue
[[ "$TS_EPOCH" -ge "$CUTOFF" ]] && echo "$line"
```

This avoids cross-midnight false counts (e.g. a session started at 23:58
yesterday appearing as "today's" login).

**rkhunter log indicators:** `[ Warning ]` is the only problem marker — it
covers everything: suspicious files, rootkit signatures, config mismatches.
`[ Found ]` means "the checked tool/file exists" (normal). Never count
`[ Found ]` as a security issue.

---

## AIDE exclusion management

Exclusions: `/etc/aide/aide.conf.d/99-exclusions` — categorised drop-in config, safe to edit (not a package script). Spaces in paths must be `\ ` escaped.

**Expected daily baseline:** `audit.log` changed (grows with auditd events — intentionally monitored as a tamper-evident file).

**After intentional changes** (new service, config edits, package installs):
```bash
sudo aide-accept   # /usr/local/bin/aide-accept — baseline only
sudo aide-check    # /usr/local/bin/aide-check  — accept + scan + send report
```

**AIDE diff attachment:** `report.sh` sends a trimmed AIDE diff as a Telegram file attachment after the main message. Filters out `audit.log` and `wtmp.db` (expected daily baseline) — only fires when unexpected changes remain.

**Trigger a fresh scan manually:**
```bash
sudo systemctl reset-failed dailyaidecheck.service
sudo systemctl start dailyaidecheck.service
journalctl -fu dailyaidecheck.service
```

---

## rkhunter setup

rkhunter's daily cron is enabled via `/etc/default/rkhunter`:
```
CRON_DAILY_RUN=yes
```
The package's `/etc/cron.daily/rkhunter` script runs it automatically.
Our `checks/rkhunter.sh` reads the resulting `/var/log/rkhunter.log`.

---

## Backup tools

Both backup tools run from root's crontab (not systemd):
- `server-backup.sh` at 04:00 → `/var/log/server-backup-cron.log`
- `recovery-snapshot.sh` at 04:30 → `/var/log/recovery-snapshot.log`

See `/usr/local/bin/CLAUDE.md` for full documentation on these tools.
