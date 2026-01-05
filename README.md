# AntiSleep.spoon

A Hammerspoon Spoon that prevents macOS from sleeping using `caffeinate` + keystroke simulation. Useful for bypassing MDM idle detection.

## Features

- **Caffeinate Integration**: Prevents system, display, and idle sleep
- **Keystroke Simulation**: Periodically simulates Shift key to bypass idle detection
- **Screen Dimming**: Gradually dims screen over time (saves power, looks natural)
- **Claude Traffic Detection**: Auto-stops when Claude Code is idle (monitors Anthropic API traffic)
- **Menubar Icon**: Visual indicator (☕ ON / 💤 OFF) with click-to-toggle

## Installation

### Option 1: Clone directly to Spoons folder

```bash
git clone https://github.com/yourusername/AntiSleep.spoon.git ~/.hammerspoon/Spoons/AntiSleep.spoon
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
```

Then reload Hammerspoon config.

## Configuration

```lua
hs.loadSpoon("AntiSleep")

-- Keystroke settings
spoon.AntiSleep.keystrokeInterval = 60      -- seconds (default: 60)

-- Dimming settings
spoon.AntiSleep.enableDimming = true        -- enable screen dimming (default: true)
spoon.AntiSleep.dimStartDelay = 300         -- start dimming after 5 min (default: 300)
spoon.AntiSleep.dimInterval = 60            -- dim every 60 sec (default: 60)
spoon.AntiSleep.dimStep = 5                 -- reduce by 5% each step (default: 5)
spoon.AntiSleep.dimMinBrightness = 20       -- minimum brightness % (default: 20)

-- Traffic monitoring settings
spoon.AntiSleep.enableTrafficWatch = true   -- auto-stop when idle (default: true)
spoon.AntiSleep.trafficGracePeriod = 1200   -- grace period 20 min (default: 1200)
spoon.AntiSleep.trafficCheckInterval = 60   -- check every 60 sec (default: 60)
spoon.AntiSleep.idleThreshold = 2           -- stop after N idle checks (default: 2)
spoon.AntiSleep.minTrafficBytes = 100       -- min bytes to consider active (default: 100)

-- UI settings
spoon.AntiSleep.showMenubar = true          -- show menubar icon (default: true)
spoon.AntiSleep.showAlerts = true           -- show on/off alerts (default: true)

spoon.AntiSleep:bindHotkeys({toggle = {{"shift", "cmd"}, "k"}})
```

## How It Works

### 1. Caffeinate
Runs `/usr/bin/caffeinate -dims` to prevent:
- `-d` Display sleep
- `-i` Idle sleep
- `-m` Disk sleep
- `-s` System sleep

### 2. Keystroke Simulation
Every 60 seconds, simulates a Shift key press/release to keep the system "active" for MDM idle detection.

### 3. Screen Dimming
After 5 minutes, gradually dims the screen by 5% every minute until reaching 20% minimum. Original brightness is restored when stopped.

### 4. Claude Traffic Detection

Monitors actual byte transfer to Anthropic API (`160.79.104.*`) using `netstat -b`:

```bash
# Check Anthropic API traffic bytes
netstat -b 2>/dev/null | grep '160.79.104'

# Output example:
tcp4  0  0  yourhost.60085  160.79.104.10.https  ESTABLISHED  13380  40408
                                                              ↑      ↑
                                                          recv_bytes send_bytes
```

| State | Byte Delta |
|-------|------------|
| **Conversation active** (Claude responding) | +tens of KB/sec |
| **Waiting** (user typing) | ~0 |
| **Completely idle** | 0 |

**Logic:**
- 20 min grace period (always stay awake)
- After grace: check every 60 seconds
- If byte delta >= 100 bytes → continue
- If byte delta < 100 bytes for 2 consecutive checks → auto-stop

**Debug logs:**
```bash
# Terminal: watch log in real-time
tail -f /tmp/antisleep.log

# Or open Hammerspoon Console: click menubar icon → Console
```

Log output example:
```
21:30:00 [AntiSleep] Traffic check: total=12345, delta=500, idle=0/2
21:31:00 [AntiSleep] Traffic check: total=12345, delta=0, idle=1/2
21:32:00 [AntiSleep] No traffic detected, stopping
```

## API

| Method | Description |
|--------|-------------|
| `:start()` | Start anti-sleep protection |
| `:stop()` | Stop anti-sleep protection |
| `:toggle()` | Toggle on/off |
| `:isRunning()` | Returns `true` if active |
| `:bindHotkeys(mapping)` | Bind keyboard shortcuts |

## Verify It's Working

```bash
# Check if caffeinate is running
pgrep caffeinate

# Check sleep assertions
pmset -g assertions | grep -E "PreventUserIdleSystemSleep|PreventUserIdleDisplaySleep"

# Check Anthropic API traffic (manual)
netstat -b 2>/dev/null | grep '160.79.104' | awk '{sum += $(NF-1) + $NF} END {print sum}'
```

## License

MIT
