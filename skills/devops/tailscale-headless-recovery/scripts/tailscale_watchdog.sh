#!/bin/bash
# Tailscale watchdog — revives the tunnel if it drops.
#
# Silent when healthy (empty stdout = no notification under no_agent cron).
# Recovery ladder: (1) `tailscale up`  →  (2) clean relaunch of the GUI app.
#
# MUST run inside the user's GUI session for step 2 to work
# (a Hermes gateway started via `launchctl kickstart gui/$(id -u)/...` qualifies).
#
# Install:
#   cp tailscale_watchdog.sh ~/.hermes/scripts/
#   cronjob(action='create', schedule='*/5 * * * *', no_agent=True,
#           script='tailscale_watchdog.sh', name='Tailscale watchdog')

TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
LOG="$HOME/.hermes/scripts/tailscale_watchdog.log"
UP_LOG="/tmp/ts_watchdog_up.txt"
CAP_SECONDS=40          # hard cap on `tailscale up` — it hangs forever when logged out

state() {
  "$TS" status --json 2>/dev/null | /usr/bin/python3 -c \
    "import json,sys
try: print(json.load(sys.stdin).get('BackendState',''))
except Exception: print('')" 2>/dev/null
}
selfip() {
  "$TS" status --json 2>/dev/null | /usr/bin/python3 -c \
    "import json,sys
try:
    d=json.load(sys.stdin); print((d.get('Self',{}).get('TailscaleIPs') or ['?'])[0])
except Exception: print('?')" 2>/dev/null
}
trimlog() { tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null; }

# ---------- also check the app binary exists at all ----------
if [ ! -x "$TS" ]; then
  echo "❌ Tailscale CLI not found at $TS — is the app installed?"
  exit 1
fi

S=$(state)

# ---------- healthy: stay silent ----------
if [ "$S" = "Running" ]; then
  echo "$(date '+%Y-%m-%d %H:%M') OK Running" >> "$LOG"
  trimlog
  exit 0
fi

# ---------- tunnel is down: recover ----------
echo "⚠️ Tailscale 掉线 (state: ${S:-unknown}) — 尝试自愈 $(date '+%Y-%m-%d %H:%M')"
echo "$(date '+%Y-%m-%d %H:%M') DOWN '$S' → reviving" >> "$LOG"

# attempt 1: CLI up, hard-capped so this can never hang a cron run
"$TS" up > "$UP_LOG" 2>&1 &
UP=$!
for _ in $(seq 1 $CAP_SECONDS); do
  sleep 1
  kill -0 $UP 2>/dev/null || break
done
if kill -0 $UP 2>/dev/null; then
  kill -9 $UP 2>/dev/null
  echo "$(date '+%Y-%m-%d %H:%M') up-hung after ${CAP_SECONDS}s (logged out?)" >> "$LOG"
fi
sleep 3
N=$(state)

# attempt 2: clean relaunch of the GUI app
if [ "$N" != "Running" ]; then
  pkill -f "Tailscale.app/Contents/MacOS/Tailscale" 2>/dev/null
  sleep 3
  open -g -a Tailscale 2>/dev/null
  sleep 12
  N=$(state)
fi

if [ "$N" = "Running" ]; then
  echo "✅ 已自愈 — Tailscale 重新上线于 $(selfip)"
  echo "$(date '+%Y-%m-%d %H:%M') RECOVERED $(selfip)" >> "$LOG"
else
  # Logged out: the only remote path is the auth URL (open it from a phone).
  echo "❌ 自愈失败 (state: ${N:-unknown}) — 需要重新登录。"
  echo "   登录链接: $("$TS" status 2>&1 | grep -i 'log in at' | head -1)"
  echo "   (在手机浏览器打开该链接即可恢复,无需物理接触机器)"
  echo "$(date '+%Y-%m-%d %H:%M') RECOVERY FAILED '$N'" >> "$LOG"
fi
trimlog
