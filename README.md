# AntiSleep.spoon

[한국어 버전](README.ko.md)

A Hammerspoon Spoon for smart sleep management during Claude Code, Codex and Cursor sessions. Monitors user activity + AI API traffic, and triggers sleep when both are idle.

## Features

- **Smart Auto-Sleep**: Triggers system sleep when both user and AI tools are idle
- **Wake Notification**: Shows notification when returning from auto-sleep (when/how long)
- **Claude Traffic Detection**: Monitors Anthropic API traffic (`160.79.104.*`)
- **Codex Traffic Detection**: Monitors `codex` process traffic per-process via `nettop` (CLI, `codex exec`, and `codex app-server`)
- **Cursor Traffic Detection**: Monitors Cursor API traffic (official domains: `*.cursor.sh`, `*.cursor-cdn.com`)
- **Screen Dimming**: Gradually dims screen while waiting (saves power)
- **Smart Unlocked Mode**: Prevents idle screen lock while AI tools are active
- **Menubar Menu**: Compact monitor status icons with start, mode switch, and stop actions

## Installation

### Option 1: Clone directly to Spoons folder

```bash
git clone https://github.com/kelion77/caffeneite.git ~/.hammerspoon/Spoons/AntiSleep.spoon
```

### Option 2: Download and copy

```bash
cp -r AntiSleep.spoon ~/.hammerspoon/Spoons/
```

## Usage

Add to your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("AntiSleep")
spoon.AntiSleep:bindHotkeys({toggle = {{"shift", "cmd"}, "k"}})
spoon.AntiSleep:start()
```

Then reload Hammerspoon config.

## Configuration

```lua
hs.loadSpoon("AntiSleep")

-- Mode settings
spoon.AntiSleep.mode = "smart"                -- "smart" or "keepUnlocked" (default: "smart")
spoon.AntiSleep.preventLockPulseInterval = 55 -- user activity pulse interval in Smart Unlocked mode

-- Sleep trigger settings
spoon.AntiSleep.sleepIdleMinutes = 2            -- sleep after X min idle (default: 2)
spoon.AntiSleep.enableAutoSleep = true          -- enable auto sleep (default: true)
spoon.AntiSleep.idleCheckInterval = 60          -- check every X sec (default: 60)
spoon.AntiSleep.minTrafficBytes = 50000         -- min bytes to consider Claude active (default: 50KB)
spoon.AntiSleep.minCursorTrafficBytes = 500000  -- min bytes to consider Cursor active (default: 500KB)
spoon.AntiSleep.minCodexTrafficBytes = 50000    -- min bytes to consider Codex active (default: 50KB)
spoon.AntiSleep.codexActiveCooldown = 600       -- keep Codex active for X sec after last burst (default: 10 min)
spoon.AntiSleep.userIdleThreshold = 120         -- user idle after X sec (default: 120)
spoon.AntiSleep.maxPreventionMinutes = 60       -- force sleep after screen locked for X min (default: 60)

-- Dimming settings
spoon.AntiSleep.enableDimming = true        -- enable screen dimming (default: true)
spoon.AntiSleep.dimStartDelay = 300         -- start dimming after 5 min (default: 300)
spoon.AntiSleep.dimInterval = 60            -- dim every 60 sec (default: 60)
spoon.AntiSleep.dimStep = 5                 -- reduce by 5% each step (default: 5)
spoon.AntiSleep.dimMinBrightness = 20       -- minimum brightness % (default: 20)

-- UI settings
spoon.AntiSleep.showMenubar = true          -- show menubar icon (default: true)
spoon.AntiSleep.showAlerts = true           -- show on/off alerts (default: true)

spoon.AntiSleep:bindHotkeys({toggle = {{"shift", "cmd"}, "k"}})
spoon.AntiSleep:start()
```

## How It Works

### 1. Modes

AntiSleep has two modes:
- **Smart Sleep** (`smart`): Existing behavior. AI traffic keeps the Mac awake, but display sleep and screen lock are allowed. Once the screen is locked and AI tools are idle, AntiSleep can trigger system sleep.
- **Smart Unlocked** (`keepUnlocked`): Uses the same AI traffic detection as Smart Sleep, but while Claude, Codex or Cursor is active it also prevents idle display sleep/screen lock. When all tools are idle, lock prevention stops.

### 2. Activity Monitoring

Monitors both user and AI tool activity:
- **User activity**: Mouse movement, clicks, scroll, keyboard input
- **Claude activity**: Anthropic API traffic (`160.79.104.*`)
- **Codex activity**: Per-process traffic of `codex` processes via `nettop`
- **Cursor activity**: Cursor API traffic (specific IPs from official domains)

#### Cursor IP Detection

Based on [Cursor's official network configuration](https://cursor.com/docs/enterprise/network-configuration), traffic is detected from:
- `*.cursor.sh` → `100.51.*`, `100.52.*`
- `*.cursor-cdn.com` → `104.26.8.*`, `104.26.9.*`, `172.67.71.*`

#### Codex Detection (per-process, not IP-based)

Codex talks to Cloudflare-shared endpoints (`api.openai.com`, `chatgpt.com`) — often over IPv6 — so IP-pattern matching would both miss traffic and false-positive on unrelated apps. Instead, traffic is measured per-process with `nettop -p codex`, which covers:
- `codex` CLI (interactive and `codex exec`)
- `codex app-server` (Codex desktop app local tasks, Claude Code Codex plugin, ChatGPT remote-control daemon)

Traffic is tracked **per connection**, not as a process-level sum: nettop reports cumulative bytes of currently open connections, so a process-level sum drops whenever a connection closes — which can mask a real burst on another connection or read as a phantom change. Per-connection counters only grow during a connection's lifetime: ongoing connections contribute their positive delta, new connections count in full, and closed connections simply drop out.

**Activity cooldown**: Real Codex work has quiet stretches — local builds/tests between API calls, long server-side reasoning, connection closes reading as zero delta. To avoid sleeping mid-work, Codex stays "active" for `codexActiveCooldown` (default 10 min) after the last traffic burst. `maxPreventionMinutes` still bounds total awake time.

### 3. Smart Sleep Trigger

**IMPORTANT**: Sleep is only triggered when the screen is locked or turned off.

```
Every 60 seconds:
├─ Screen locked/off?
├─ Claude idle? (API traffic delta < 50KB)
├─ Codex idle? (process traffic delta < 50KB)
├─ Cursor idle? (API traffic delta < 500KB)
├─ Max prevention time exceeded? (locked > 60 min)
│
├─ SCREEN LOCKED + (ALL IDLE or MAX TIME EXCEEDED) → increment idle counter
│   └─ 2 min reached → pause monitoring + pmset sleepnow
│                       (timers stop, sleepWatcher stays active)
│
└─ SCREEN UNLOCKED or ANY AI ACTIVE → reset counter
```

**Max Prevention Time**: Even if AI traffic is detected, sleep is forced after 60 minutes of screen lock to prevent battery drain from background traffic.

**Auto-restart after sleep**:
- When sleep is triggered, monitoring pauses but sleepWatcher stays active
- On wake (`systemDidWake` event), monitoring automatically restarts
- Ensures sleep doesn't repeat immediately after waking

### 4. Sleep Prevention (caffeinate)

In Smart Sleep mode, when Claude, Codex or Cursor is active:
- `caffeinate -is` is started to prevent idle/system sleep
- Display sleep still works, so screen lock is allowed
- When all become idle, caffeinate stops

In Smart Unlocked mode, when Claude, Codex or Cursor is active:
- `caffeinate -dis` is started to prevent display sleep and system sleep
- A periodic user activity assertion helps prevent idle lock/screen saver activation
- When all become idle, lock prevention and caffeinate stop

### 5. Wake Notification

When you return from auto-sleep:
- System notification shows when sleep occurred and duration
- On-screen alert: "Woke from auto-sleep (X min)"
- Logged to `/tmp/antisleep.log`

### 6. Screen Dimming

After 5 minutes, gradually dims screen by 5% per minute until 20% minimum. Original brightness restored when activity detected.

## Debug Logs

```bash
# Watch log in real-time
tail -f /tmp/antisleep.log

# Or open Hammerspoon Console: click menubar icon → Console
```

Log output example:
```
07:41:36 [AntiSleep] Check: screen=UNLOCKED, Claude=525.2 KB, Cursor=1.2 MB, Codex=3.4 MB, caffeinate=ON, idle=0s/120s
07:42:36 [AntiSleep] Check: screen=UNLOCKED, Claude=0 B, Cursor=0 B, Codex=0 B, caffeinate=OFF, idle=0s/120s
07:43:00 [AntiSleep] Event: screensDidLock
07:45:00 [AntiSleep] Auto-sleep triggered (ran for 45 min)
08:30:00 [AntiSleep] Woke from auto-sleep (duration: 45 min)
```

## API

| Method | Description |
|--------|-------------|
| `:start()` | Start smart sleep monitoring |
| `:stop()` | Stop monitoring completely (including sleepWatcher) |
| `:pause()` | Pause monitoring but keep sleepWatcher for auto-restart |
| `:toggle()` | Toggle on/off |
| `:startMode(mode)` | Select a mode and start monitoring if needed |
| `:setMode(mode)` | Set mode to `"smart"` or `"keepUnlocked"` |
| `:isRunning()` | Returns `true` if active |
| `:bindHotkeys(mapping)` | Bind keyboard shortcuts |

## Verify It's Working

```bash
# Check Claude (Anthropic) API traffic
netstat -b 2>/dev/null | grep '160.79.104' | awk '{sum += $(NF-1) + $NF} END {print sum}'

# Check Cursor API traffic
netstat -b 2>/dev/null | grep -E '100.51|100.52|104.26.8|104.26.9' | awk '{sum += $(NF-1) + $NF} END {print sum}'

# Check Codex process traffic
nettop -x -l 1 -p codex -J bytes_in,bytes_out 2>/dev/null | awk '$1 ~ /^codex\./ {sum += $2 + $3} END {print sum+0}'

# Check sleep log
pmset -g log | grep -i "sleep" | tail -5
```

## License

MIT
