# AntiSleep.spoon

[한국어 버전](README.ko.md)

A Hammerspoon Spoon for smart sleep management during Claude Code and Cursor sessions. Monitors user activity + AI API traffic, and triggers sleep when both are idle.

## Features

- **Smart Auto-Sleep**: Triggers system sleep when both user and AI tools are idle
- **Wake Notification**: Shows notification when returning from auto-sleep (when/how long)
- **Claude Traffic Detection**: Monitors Anthropic API traffic (`160.79.104.*`)
- **Cursor Traffic Detection**: Monitors Cursor API traffic (official domains: `*.cursor.sh`, `*.cursor-cdn.com`)
- **Screen Dimming**: Gradually dims screen while waiting (saves power)
- **Menubar Icon**: Visual indicator (👁 Monitoring / 💤 OFF) with click-to-toggle

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

-- Sleep trigger settings
spoon.AntiSleep.sleepIdleMinutes = 2            -- sleep after X min idle (default: 2)
spoon.AntiSleep.enableAutoSleep = true          -- enable auto sleep (default: true)
spoon.AntiSleep.idleCheckInterval = 60          -- check every X sec (default: 60)
spoon.AntiSleep.minTrafficBytes = 50000         -- min bytes to consider Claude active (default: 50KB)
spoon.AntiSleep.minCursorTrafficBytes = 500000  -- min bytes to consider Cursor active (default: 500KB)
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

### 1. Activity Monitoring

Monitors both user and AI tool activity:
- **User activity**: Mouse movement, clicks, scroll, keyboard input
- **Claude activity**: Anthropic API traffic (`160.79.104.*`)
- **Cursor activity**: Cursor API traffic (specific IPs from official domains)

#### Cursor IP Detection

Based on [Cursor's official network configuration](https://cursor.com/docs/enterprise/network-configuration), traffic is detected from:
- `*.cursor.sh` → `100.51.*`, `100.52.*`
- `*.cursor-cdn.com` → `104.26.8.*`, `104.26.9.*`, `172.67.71.*`

### 2. Smart Sleep Trigger

**IMPORTANT**: Sleep is only triggered when the screen is locked or turned off.

```
Every 60 seconds:
├─ Screen locked/off?
├─ Claude idle? (API traffic delta < 50KB)
├─ Cursor idle? (API traffic delta < 500KB)
├─ Max prevention time exceeded? (locked > 60 min)
│
├─ SCREEN LOCKED + (BOTH IDLE or MAX TIME EXCEEDED) → increment idle counter
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

### 3. Sleep Prevention (caffeinate)

When Claude or Cursor is active:
- `caffeinate -i` is started to prevent idle system sleep
- Display sleep still works (screen lock is allowed)
- When both become idle, caffeinate stops

### 4. Wake Notification

When you return from auto-sleep:
- System notification shows when sleep occurred and duration
- On-screen alert: "Woke from auto-sleep (X min)"
- Logged to `/tmp/antisleep.log`

### 5. Screen Dimming

After 5 minutes, gradually dims screen by 5% per minute until 20% minimum. Original brightness restored when activity detected.

## Debug Logs

```bash
# Watch log in real-time
tail -f /tmp/antisleep.log

# Or open Hammerspoon Console: click menubar icon → Console
```

Log output example:
```
07:41:36 [AntiSleep] Check: screen=UNLOCKED, Claude=525.2 KB, Cursor=1.2 MB, caffeinate=ON, idle=0s/120s
07:42:36 [AntiSleep] Check: screen=UNLOCKED, Claude=0 B, Cursor=0 B, caffeinate=OFF, idle=0s/120s
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
| `:isRunning()` | Returns `true` if active |
| `:bindHotkeys(mapping)` | Bind keyboard shortcuts |

## Verify It's Working

```bash
# Check Claude (Anthropic) API traffic
netstat -b 2>/dev/null | grep '160.79.104' | awk '{sum += $(NF-1) + $NF} END {print sum}'

# Check Cursor API traffic
netstat -b 2>/dev/null | grep -E '100.51|100.52|104.26.8|104.26.9' | awk '{sum += $(NF-1) + $NF} END {print sum}'

# Check sleep log
pmset -g log | grep -i "sleep" | tail -5
```

## License

MIT
