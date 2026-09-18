---
name: tailscale-headless-recovery
description: Use when macOS Tailscale is down and unreachable remotely.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags:
      - tailscale
      - macos
      - networking
      - remote-access
      - headless
      - cron
    related_skills:
      - hermes-cron-ops
      - macos-lan-webapps
---

# macOS Tailscale Headless Recovery

## When to Use

- Tailscale on a Mac reports `stopped`, `NeedsLogin`, or peers just say `offline`.
- You tried `tailscale up` and it hung with no output.
- The Mac is unreachable over its tailnet IP from another device.
- You need to decide whether a drop can be fixed remotely or genuinely needs someone at the machine.
- You want the tunnel to come back by itself after a reboot or crash.

Do **not** use this for the open-source `tailscaled` daemon (brew install) — that runs as a root LaunchDaemon and is restarted with `sudo brew services restart tailscale` / `sudo tailscale up` and has none of the GUI-session constraints below.

## Overview

Recovering a dropped Tailscale tunnel on a Mac you can only reach remotely, and hardening it so a drop never becomes a permanent lockout.

**Core insight (verified):** the macOS Tailscale tunnel (network extension) is more resilient than the GUI app process. `tailscale up` works headlessly **while authenticated** and returns in seconds; it **hangs forever** only when the node is logged out. So "can't restart without physical login" is usually wrong — but "logged out with no SSH" really is a hard lockout.

## Diagnose first

```bash
TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
"$TS" status --json | python3 -c "import json,sys;d=json.load(sys.stdin);print('state:',d.get('BackendState'));print('ip:',(d.get('Self',{}).get('TailscaleIPs') or ['?'])[0])"
"$TS" status | head -5          # shows "Log in at: https://login.tailscale.com/a/..." when logged out
```

`BackendState` values that matter: `Running` (fine), `Stopped` (recoverable), `NeedsLogin` (needs auth).

Also check the escape hatches — if all are closed, a real lockout is possible:

```bash
launchctl print gui/$(id -u) >/dev/null 2>&1 && echo "GUI session exists" || echo "NO GUI session"
stat -f %Su /dev/console                     # who owns the console
launchctl print system/com.openssh.sshd 2>/dev/null && echo "SSH on" || echo "SSH off"
lsof -nP -iTCP:5900 -sTCP:LISTEN 2>/dev/null  # Screen Sharing
```

## Recovery ladder

```bash
# 1. CLI up — ALWAYS hard-cap this; it hangs forever when logged out.
"$TS" up > /tmp/tsup.txt 2>&1 &
UP=$!; for i in $(seq 1 40); do sleep 1; kill -0 $UP 2>/dev/null || break; done
kill -0 $UP 2>/dev/null && kill -9 $UP 2>/dev/null

# 2. Only if step 1 failed: clean relaunch of the GUI app (needs a GUI session)
pkill -f "Tailscale.app/Contents/MacOS/Tailscale"; sleep 3; open -g -a Tailscale; sleep 12

# 3. Verify for real — an IP alone is not proof
"$TS" status --json | python3 -c "import json,sys;print(json.load(sys.stdin).get('BackendState'))"
ping -c 2 -t 5 100.100.100.100        # coordination server
curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://<tailnet-ip>:<port>/
```

**If the node is logged out**, the only remote path is the `Log in at:` URL — open it from a phone; the Mac's app picks up the auth without anyone touching it. Then hand off to hardening below.

## Pitfalls (all verified the hard way)

| Wrong move | Reality |
|---|---|
| `rm` an app in `/Applications` | Root-owned; `rm` fails. Use `osascript -e 'tell application "Finder" to delete POSIX file "..."'` — Finder holds the delete privilege. Then empty the Trash or no space is freed. |
| Assuming `kill` of the GUI process drops the tunnel | It usually does **not** — the extension persists and state stays `Running`. |
| `kill + open -a Tailscale` to fix a `Stopped` node | **Does not work.** Use `tailscale up`. |
| Running `tailscale up` unbounded | Hangs indefinitely when logged out — always cap it or it wedges your cron run. |
| GUI scripting via `osascript` | Times out (`-1712`) without Accessibility permission. Don't rely on it. |
| App Store build (`Contents/_MASReceipt` exists) | Sandboxed → **cannot** install a system extension → structurally tied to a GUI login. |

## Prevention (do these while you still have access)

1. **Enable SSH** — System Settings → General → Sharing → Remote Login. The LAN lifeline; independent of Tailscale. Highest-value single action.
2. **Enable auto-login** — Users & Groups → Automatically log in as…. Guarantees the GUI session exists so the login-item tunnel starts after a reboot.
3. **Install the self-healing watchdog** — `scripts/tailscale_watchdog.sh` (see below).
4. **For true headless permanence**, replace the sandboxed app with the open-source daemon:
   ```bash
   brew install tailscale
   sudo brew services start tailscale          # root LaunchDaemon: starts at boot, no login
   sudo tailscale up --authkey=tskey-auth-…    # non-interactive forever
   ```
   ⚠️ Joins as a **new node** — the tailnet IP changes, so update bookmarks.

## Watchdog

`scripts/tailscale_watchdog.sh` — silent when healthy, two-stage recovery when not. Install as a `no_agent` cron job (`*/5 * * * *`) so empty stdout means no notification:

```
cronjob(action='create', schedule='*/5 * * * *', no_agent=True,
        script='tailscale_watchdog.sh', name='Tailscale watchdog')
```

It must run inside the user's GUI session (a Hermes gateway launched via `launchctl … gui/$(id -u)` qualifies) for the `open -a` fallback to work.

## Common mistakes

- Declaring success from `status` listing peers — check `BackendState == Running` **and** ping a peer.
- Forgetting that a GUI-app tunnel needs a *logged-in console session* to start after a reboot.
- Killing Tailscale to "test" recovery on a machine you can only reach *through* Tailscale. Have SSH first.
