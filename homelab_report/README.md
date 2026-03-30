# homelab_report

Sends a daily Telegram message summarising the security posture, system health,
and backup status of a Debian-based homelab server. Fires at noon via a systemd
timer; no persistent process, no framework — just shell and curl.

## What it reports

```
🏠 Homelab Report — 2026-03-29 12:00

🛡 Security
  AIDE:        No changes detected
  ClamAV:      Clean  (scan 2026-03-28)
  rkhunter:    0 warnings
  Auth:        3 sudo events, 0 su events (last 24h)
  Fail2ban:    2 IPs banned (last 24h)

💾 Disk  [checked 12:00]
  /:           18G / 117G (16%)
  /mnt/storage: 2.8T / 3.6T (79%)

🖥 System  [checked 12:00]
  Uptime:      14 days
  Updates:     2 security updates pending
  Memory:      3.1G / 7.8G (40%)
  SMART:       sda OK  sdb OK  nvme0n1 OK
  Docker:      8 running, 0 stopped
  Logins:      3 in last 24h
               apollo from 192.168.0.138 at 03-29, last 09:14, (3)

🗄 Backups
  server-backup:       OK  2026-03-29 04:00  (14G)
  recovery-snapshot:   OK  2026-03-29 04:31
```

## Requirements

- Debian/Ubuntu server
- `curl` (standard on Debian)
- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- Root access (reads system logs and runs `smartctl`, `docker ps`, etc.)

Optional (checks are skipped if not installed):
- `aide`, `clamav`, `rkhunter`, `fail2ban`, `smartmontools`, `docker`

## Setup

**1. Clone and enter the directory**

```bash
git clone https://github.com/YOUR_USERNAME/tg.git /srv/services/tg
cd /srv/services/tg/homelab_report
```

**2. Create and secure the credentials file**

```bash
sudo cp .env.example .env
sudo chown root:root .env
sudo chmod 600 .env
sudo nano .env          # fill in TG_BOT_TOKEN and TG_CHAT_ID
```

To find your `TG_CHAT_ID`: send any message to your bot, then call:
```bash
curl "https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates"
# look for: "chat": {"id": 123456789}
```

**3. Make scripts executable**

```bash
sudo chmod +x report.sh checks/*.sh
```

**4. Test manually**

```bash
sudo bash report.sh
```

This sends a real message to your Telegram chat.

**5. Set up the systemd timer**

Create `/etc/systemd/system/tg-homelab-report.service`:
```ini
[Unit]
Description=Homelab Telegram daily report

[Service]
Type=oneshot
ExecStart=/bin/bash /srv/services/tg/homelab_report/report.sh
```

Create `/etc/systemd/system/tg-homelab-report.timer`:
```ini
[Unit]
Description=Run homelab Telegram report daily at noon

[Timer]
OnCalendar=*-*-* 12:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now tg-homelab-report.timer
sudo systemctl list-timers | grep tg-
```

## Checks

| Script | Source | Description |
|--------|--------|-------------|
| `aide.sh` | `/var/log/aide/aide-YYYY-MM-DD.log` | File integrity changes |
| `clamav.sh` | `/var/log/clamav/weekly-scan.log` | Antivirus scan result |
| `rkhunter.sh` | `/var/log/rkhunter.log` | Rootkit scan warnings |
| `auth.sh` | `/var/log/auth.log` | sudo/su events in last 24h |
| `fail2ban.sh` | `fail2ban-client` | Banned IPs in last 24h |
| `disk.sh` | `df -h` | Usage for /, /mnt/storage, /mnt/cloud |
| `system.sh` | `uptime`, `apt`, `/var/run/reboot-required` | Uptime, pending updates, reboot flag |
| `memory.sh` | `/proc/meminfo` | RAM usage |
| `smart.sh` | `smartctl -H` | Drive health for sda, sdb, nvme0n1 |
| `docker.sh` | `docker ps -a` | Running and stopped container counts |
| `logins.sh` | `last` | Successful logins in last 24h, grouped by user+IP+date with count |
| `systemd.sh` | `systemctl --failed` | Failed systemd units (omitted if none) |
| `backup.sh` | `/var/log/server-backup-cron.log` | Backup job results |

Each check script is independent — a failure in one never blocks the others or
prevents the report from sending.

## AIDE diff attachment

When AIDE detects unexpected filesystem changes, `report.sh` sends a trimmed
diff as a file attachment — as a reply to the main report message. Known
daily changes (`audit.log`, `wtmp.db`) are filtered out automatically; the
attachment only appears when something genuinely unexpected has changed.

## Adding a new check

1. Create `checks/newcheck.sh`:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   # Always exit 0 — never abort the report
   echo "  Label:    result"
   ```

2. `chmod +x checks/newcheck.sh`

3. In `report.sh`, add `NEWCHECK=$(run_check newcheck.sh)` and include
   `${NEWCHECK}` in the relevant `MSG` section.

## Debugging

```bash
# Run a single check
sudo bash checks/aide.sh

# Check the last timer run
journalctl -u tg-homelab-report.service -n 50

# Test Telegram connectivity
source .env
curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getMe"
```
