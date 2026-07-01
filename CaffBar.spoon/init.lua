--- === CaffBar ===
---
--- Smart awake management for Claude Code / Codex / Cursor sessions.
--- Monitors user activity + AI tool traffic, triggers sleep when both are idle.
---
--- Features:
---   - Traffic-based auto sleep (sleeps when both user and Claude are idle)
---   - Wake notification (shows when auto-sleep occurred)
---   - Gradual screen dimming (saves power while waiting)

local obj = {}
obj.__index = obj

local sourceFile = debug.getinfo(1, "S").source
local spoonPath = sourceFile and sourceFile:match("^@(.+)/init%.lua$")

-- Metadata
obj.name = "CaffBar"
obj.version = "1.5.0"
obj.author = "sung-lee"
obj.license = "MIT"
obj.homepage = "https://github.com/kelion77/caffeneite"

-- Internal state
obj.enabled = false
obj.dimTimer = nil
obj.idleCheckTimer = nil
obj.menubar = nil
obj.spoonPath = spoonPath
obj.originalBrightness = nil
obj.currentBrightness = nil
obj.startTime = nil
obj.mode = "smart"                 -- smart | keepUnlocked
obj.lastClaudeBytes = nil         -- for Claude delta calculation
obj.lastCursorBytes = nil         -- for Cursor delta calculation
obj.lastCodexConns = nil          -- per-connection byte counts for Codex delta calculation
obj.lastCodexActiveTime = nil     -- when Codex traffic last exceeded threshold (for cooldown)
obj.consecutiveIdleSeconds = 0
obj.userActivityWatcher = nil
obj.sleepWatcher = nil
obj.sleepTriggeredByUs = false
obj.lastSleepTime = nil
obj.sleepOccurredWhileLocked = false  -- track if sleep happened while screen locked
obj.screenLockedTime = nil            -- when screen was locked (for prevention time calc)
obj.preventionDuration = nil          -- how long sleep was prevented (lock → sleep)
obj.sleepTriggerPending = false       -- prevent repeated pmset sleepnow calls
obj.sleepTriggeredTime = nil          -- when sleep was triggered (for grace period)
obj.isScreenLocked = false        -- track if screen is locked
obj.caffeinateTask = nil          -- caffeinate process for sleep prevention
obj.isCaffeinateRunning = false   -- track caffeinate state
obj.caffeinateMode = nil          -- smart | keepUnlocked
obj.preventLockTimer = nil        -- periodic user activity assertion for keep-unlocked mode
obj._menubarIconCache = nil       -- cached hs.image objects

-- Configuration
obj.showMenubar = true          -- show menubar icon
obj.showAlerts = true           -- show on/off alerts
obj.autoLaunchHammerspoon = true -- launch Hammerspoon at login
obj.preventLockPulseInterval = 55 -- seconds between user activity assertions in keep-unlocked mode
obj.menubarIconSize = 24        -- status bar icon size in pixels
obj.menubarIcons = {
    smart = "assets/icons/status-smart.png",
    keepUnlocked = "assets/icons/status-unlocked.png",
    off = "assets/icons/status-off.png",
}

-- Dimming configuration
obj.enableDimming = false       -- DISABLED - was dimming during active use
obj.dimStartDelay = 300         -- start dimming after 5 minutes (seconds)
obj.dimInterval = 60            -- dim every 60 seconds
obj.dimStep = 5                 -- reduce brightness by 5% each step
obj.dimMinBrightness = 20       -- minimum brightness (%)

-- Sleep trigger configuration
obj.sleepIdleMinutes = 2        -- trigger sleep after X minutes of combined idle
obj.enableAutoSleep = true      -- enable automatic sleep trigger
obj.idleCheckInterval = 60      -- check idle status every 60 seconds
obj.minTrafficBytes = 50000     -- minimum bytes delta to consider Claude "active" (50KB)
obj.minCursorTrafficBytes = 500000  -- minimum bytes delta to consider Cursor "active" (500KB, filters out idle keep-alive/telemetry)
obj.minCodexTrafficBytes = 50000    -- minimum bytes delta to consider Codex "active" (50KB)
                                    -- calibrated live: active-light sessions show 55-90KB/min,
                                    -- idle floor is ~0-12KB/min
obj.codexActiveCooldown = 600       -- keep Codex "active" for X sec after last traffic burst (10 min)
                                    -- bridges quiet stretches during real work: local builds/tests,
                                    -- long server-side reasoning, and connection-close artifacts
obj.userIdleThreshold = 120     -- user idle seconds to consider user "inactive" (2 min)
obj.sleepGracePeriod = 180      -- don't restart caffeinate for X sec after sleep trigger (3 min)
obj.maxPreventionMinutes = 60   -- force sleep after screen locked for this long, regardless of traffic

-- API IP patterns
obj.claudeIpPatterns = {
    "160.79.104",   -- Anthropic (Claude Code)
}
-- Cursor IP patterns (observed from actual connections)
-- 104.18 = Cloudflare (cursor-cdn.com, extensions)
-- 75.2.76 = AWS Global Accelerator
-- 52.86, 35.71, 52.1, 3.218 = AWS (api servers)
obj.cursorIpPatterns = {
    "104.18",       -- Cloudflare CDN (stable)
    "75.2.76",      -- AWS Global Accelerator (stable)
}
-- DNS domains for dynamic IP refresh (adds to static patterns)
obj.cursorDomains = {
    "api2.cursor.sh",
    "api3.cursor.sh",
}
obj.cursorDnsRefreshInterval = 1800  -- refresh DNS every 30 minutes
obj.cursorDnsTimer = nil

-- Codex process names for per-process traffic monitoring (nettop)
-- Codex talks to Cloudflare-shared IPs (api.openai.com / chatgpt.com), often over
-- IPv6, so netstat IP-pattern matching would both miss traffic (IPv6) and
-- false-positive (shared IPs). Per-process nettop is accurate instead.
-- "codex" covers: codex CLI, codex exec, and `codex app-server`
-- (desktop app local tasks, Claude Code plugin broker, remote-control daemon)
obj.codexProcessNames = {
    "codex",
}

--- CaffBar:refreshCursorIPs()
--- Method
--- Add DNS-resolved IPs to static Cursor patterns
function obj:refreshCursorIPs()
    -- Start with static patterns
    local staticPatterns = {"104.18", "75.2.76"}
    local patterns = {}
    local seen = {}

    -- Add static patterns first
    for _, p in ipairs(staticPatterns) do
        seen[p] = true
        table.insert(patterns, p)
    end

    -- Add DNS-resolved patterns (only 100.x which are AWS Global Accelerator)
    for _, domain in ipairs(self.cursorDomains) do
        local cmd = string.format("dig +short %s A 2>/dev/null", domain)
        local output, status = hs.execute(cmd)
        if status and output then
            for ip in output:gmatch("(%d+%.%d+%.%d+%.%d+)") do
                if ip:match("^100%.") then
                    local pattern = ip:match("^(%d+%.%d+)")  -- e.g., "100.52"
                    if pattern and not seen[pattern] then
                        seen[pattern] = true
                        table.insert(patterns, pattern)
                    end
                end
            end
        end
    end

    self.cursorIpPatterns = patterns
    local logMsg = string.format("[CaffBar] Cursor IPs: %s", table.concat(patterns, ", "))
    print(logMsg)
    local f = io.open("/tmp/caffbar.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end
end

--- CaffBar:init()
--- Method
--- Initialize the Spoon
function obj:init()
    -- SAFETY: Kill any orphan caffeinate from previous sessions
    hs.execute("killall caffeinate 2>/dev/null")

    if self.autoLaunchHammerspoon and hs.autoLaunch then
        local ok, err = pcall(function()
            hs.autoLaunch(true)
        end)
        if not ok then
            local logMsg = "[CaffBar] WARN: autoLaunch failed: " .. tostring(err)
            print(logMsg)
            local f = io.open("/tmp/caffbar.log", "a")
            if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end
        end
    end

    if self.showMenubar then
        self.menubar = hs.menubar.new()
        if self.menubar then
            self.menubar:setMenu(function() return self:menuItems() end)
        end
    end
    self:updateMenubar()
    print("[CaffBar] Initialized")
    return self
end

--- CaffBar:formatBytes(bytes)
--- Method
--- Format bytes to human readable string
function obj:formatBytes(bytes)
    if not bytes or bytes < 0 then
        return "0 B"
    elseif bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return string.format("%.1f MB", bytes / (1024 * 1024))
    end
end

--- CaffBar:updateMenubar()
--- Method
--- Update menubar icon and tooltip
function obj:updateMenubar()
    if not self.menubar then return end

    local tooltip = "CaffBar: "
    if self.enabled then
        local elapsed = ""
        local status = ""
        local modeLabel = self.mode == "keepUnlocked" and "Smart Unlocked" or "Smart Awake"
        if self.startTime then
            local secs = os.time() - self.startTime
            local mins = math.floor(secs / 60)
            elapsed = string.format(" (%dm)", mins)

            -- Show screen lock status
            status = string.format("\nScreen: %s", self.isScreenLocked and "LOCKED" or "unlocked")

            -- Show idle countdown if screen is locked and idle time is accumulating
            if self.isScreenLocked and self.consecutiveIdleSeconds > 0 then
                local sleepThresholdSecs = self.sleepIdleMinutes * 60
                local remaining = sleepThresholdSecs - self.consecutiveIdleSeconds
                if remaining > 0 then
                    status = status .. string.format("\nSleep in: %ds", remaining)
                end
            end

            -- Show caffeinate status
            status = status .. string.format("\nCaffeinate: %s", self.isCaffeinateRunning and "ON" or "OFF")
        end
        self:setMenubarIcon(self.mode)
        tooltip = tooltip .. modeLabel .. elapsed .. status
    else
        self:setMenubarIcon("off")
        tooltip = tooltip .. "OFF"
    end

    self.menubar:setTooltip(tooltip)
end

--- CaffBar:assetPath(relativePath)
--- Method
--- Resolve a path relative to this Spoon.
function obj:assetPath(relativePath)
    if not self.spoonPath then return nil end
    return self.spoonPath .. "/" .. relativePath
end

--- CaffBar:loadMenubarIcon(state)
--- Method
--- Load and cache a menu bar icon for a state.
function obj:loadMenubarIcon(state)
    self._menubarIconCache = self._menubarIconCache or {}
    if self._menubarIconCache[state] then
        return self._menubarIconCache[state]
    end

    local relativePath = self.menubarIcons[state]
    if not relativePath then return nil end

    local path = self:assetPath(relativePath)
    if not path then return nil end

    local icon = hs.image.imageFromPath(path)
    if not icon then return nil end

    icon = icon:setSize({ w = self.menubarIconSize, h = self.menubarIconSize })
    self._menubarIconCache[state] = icon
    return icon
end

--- CaffBar:setMenubarIcon(state)
--- Method
--- Set the menu bar icon image for a state.
function obj:setMenubarIcon(state)
    local icon = self:loadMenubarIcon(state)
    if not icon then return false end

    self.menubar:setTitle("")
    self.menubar:setIcon(icon, false)
    self.menubar:imagePosition(hs.menubar.imagePositions.imageOnly)
    return true
end

--- CaffBar:menuItems()
--- Method
--- Build menubar menu items
function obj:menuItems()
    local modeLabel = self.mode == "keepUnlocked" and "Smart Unlocked" or "Smart Awake"
    local statusLabel = self.enabled and ("Status: ON - " .. modeLabel) or "Status: OFF"
    local smartTitle = self.enabled and "Smart Awake" or "Start Smart Awake"
    local keepUnlockedTitle = self.enabled and "Smart Unlocked" or "Start Smart Unlocked"

    return {
        { title = statusLabel, disabled = true },
        { title = "-" },
        { title = smartTitle, checked = self.enabled and self.mode == "smart", fn = function() self:startMode("smart") end },
        { title = keepUnlockedTitle, checked = self.enabled and self.mode == "keepUnlocked", fn = function() self:startMode("keepUnlocked") end },
        { title = "-" },
        { title = "Stop", disabled = not self.enabled, fn = function() self:stop() end },
    }
end

--- CaffBar:startMode(mode)
--- Method
--- Select a mode and start monitoring if needed.
function obj:startMode(mode)
    self:setMode(mode)
    if not self.enabled then
        self:start()
    end
    return self
end

--- CaffBar:setMode(mode)
--- Method
--- Set operating mode: smart or keepUnlocked
function obj:setMode(mode)
    if mode ~= "smart" and mode ~= "keepUnlocked" then
        return self
    end
    if self.mode == mode then
        return self
    end

    self.mode = mode

    if self.enabled then
        if self.mode == "keepUnlocked" then
            if self.isCaffeinateRunning then
                self:startPreventLockTimer()
                self:startCaffeinate()
            end
        else
            self:stopPreventLockTimer()
            if self.isCaffeinateRunning then
                self:startCaffeinate()
            end
        end
    end

    self:updateMenubar()

    if self.showAlerts then
        local msg = self.mode == "keepUnlocked"
            and "🔓 CaffBar: Smart Unlocked"
            or "👁 CaffBar: Smart Awake"
        hs.alert.show(msg, 2)
    end

    return self
end

--- CaffBar:isUserActive()
--- Method
--- Check if user is actively using the computer (based on system idle time)
function obj:isUserActive()
    local idleTime = hs.host.idleTime()  -- system idle time in seconds
    return idleTime < self.userIdleThreshold
end

--- CaffBar:getUserIdleTime()
--- Method
--- Get seconds since last user activity
function obj:getUserIdleTime()
    return hs.host.idleTime()
end

--- CaffBar:dimScreen()
--- Method
--- Gradually dim the screen (only when user is idle)
function obj:dimScreen()
    if not self.enabled or not self.enableDimming then return end
    if not self.startTime then return end

    local elapsed = os.time() - self.startTime
    if elapsed < self.dimStartDelay then return end

    local idleTime = hs.host.idleTime()

    -- If user is active, restore brightness
    if idleTime < self.userIdleThreshold then
        if self.originalBrightness and self.currentBrightness then
            hs.brightness.set(self.originalBrightness)
            self.currentBrightness = nil
            local logMsg = string.format("[CaffBar] Dim: restored (userIdle=%.0fs < %ds)", idleTime, self.userIdleThreshold)
            print(logMsg)
            local f = io.open("/tmp/caffbar.log", "a")
            if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end
        end
        return
    end

    -- User is idle, dim the screen
    local currentBrightness = hs.brightness.get()
    if currentBrightness and currentBrightness > self.dimMinBrightness then
        local newBrightness = math.max(currentBrightness - self.dimStep, self.dimMinBrightness)
        hs.brightness.set(newBrightness)
        self.currentBrightness = newBrightness
        local logMsg = string.format("[CaffBar] Dim: %d%% -> %d%% (userIdle=%.0fs)", currentBrightness, newBrightness, idleTime)
        print(logMsg)
        local f = io.open("/tmp/caffbar.log", "a")
        if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end
    end
end

--- CaffBar:restoreBrightness()
--- Method
--- Restore original screen brightness
function obj:restoreBrightness()
    if self.originalBrightness then
        hs.brightness.set(self.originalBrightness)
        self.originalBrightness = nil
        self.currentBrightness = nil
    end
end

--- CaffBar:getCodexTrafficBytes()
--- Method
--- Get total bytes transferred by Codex processes (per-process via nettop)
function obj:getCodexTrafficBytes()
    local total = 0
    for _, name in ipairs(self.codexProcessNames) do
        -- Summary rows look like "codex.12345  <bytes_in>  <bytes_out>";
        -- connection rows start with tcp/udp, so anchor on the process name.
        -- NOTE: do NOT use `-t external` — it filters by physical interface and
        -- drops VPN-tunneled traffic (e.g. CloudflareWARP routes Codex over a
        -- utun tunnel as 100.64.0.0/10 CGNAT, which nettop won't class external).
        local cmd = string.format(
            "nettop -x -l 1 -p %s -J bytes_in,bytes_out 2>/dev/null | awk '$1 ~ /^%s\\./ {sum += $2 + $3} END {print sum+0}'",
            name, name
        )
        local output, status = hs.execute(cmd)
        if status and output then
            total = total + (tonumber(output:match("%d+")) or 0)
        end
    end
    return total
end

--- CaffBar:getCodexTrafficDelta()
--- Method
--- Get bytes transferred by Codex processes since the last call, tracked
--- PER CONNECTION. nettop reports cumulative bytes of currently open
--- connections, so a process-level sum drops when any connection closes —
--- which can mask a real burst on another connection (observed live) or
--- read as a phantom change. Per-connection counters only ever grow during
--- a connection's lifetime, so:
---   - ongoing connection → its positive delta counts
---   - new connection     → all its bytes count
---   - closed connection  → simply drops out (contributes 0, masks nothing)
function obj:getCodexTrafficDelta()
    local conns = {}
    for _, name in ipairs(self.codexProcessNames) do
        -- Connection rows look like "tcp6 <src><-><dst>  <bytes_in>  <bytes_out>"
        -- Exclude loopback in awk rather than via nettop's `-t external` flag:
        -- `-t external` filters by physical interface and silently drops
        -- VPN-tunneled traffic (CloudflareWARP routes Codex over a utun tunnel
        -- as 100.64.0.0/10 CGNAT), which would zero out detection while a VPN
        -- is active. The loopback filter keeps the same noise-reduction intent.
        local cmd = string.format(
            "nettop -x -l 1 -p %s -J bytes_in,bytes_out 2>/dev/null | awk '$1 ~ /^(tcp|udp)/ && $2 !~ /127\\.0\\.0\\.1|::1/ {print $2, $3 + $4}'",
            name
        )
        local output, status = hs.execute(cmd)
        if status and output then
            for conn, bytes in output:gmatch("(%S+)%s+(%d+)") do
                conns[conn] = (conns[conn] or 0) + tonumber(bytes)
            end
        end
    end

    local delta = 0
    if self.lastCodexConns then
        for conn, bytes in pairs(conns) do
            local prev = self.lastCodexConns[conn]
            if prev then
                local d = bytes - prev
                if d > 0 then delta = delta + d end
            else
                delta = delta + bytes  -- new connection since last check
            end
        end
    end
    self.lastCodexConns = conns
    return delta
end

--- CaffBar:getTrafficBytesSeparate()
--- Method
--- Get bytes transferred separately for Claude and Cursor (netstat IP-based).
--- Codex is measured separately via getCodexTrafficDelta() (per-connection).
function obj:getTrafficBytesSeparate()
    local claudeBytes = 0
    local cursorBytes = 0

    -- Get Claude traffic (bytes via netstat - Anthropic IP is unique)
    local claudePattern = table.concat(self.claudeIpPatterns, "|")
    local claudeCmd = string.format(
        "netstat -bn 2>/dev/null | grep -E '%s' | awk '{sum += $(NF-1) + $NF} END {print sum+0}'",
        claudePattern
    )
    local output, status = hs.execute(claudeCmd)
    if status and output then
        claudeBytes = tonumber(output:match("%d+")) or 0
    end

    -- Get Cursor traffic (bytes via netstat - using Cursor IP patterns)
    if #self.cursorIpPatterns > 0 then
        local cursorPattern = table.concat(self.cursorIpPatterns, "|")
        local cursorCmd = string.format(
            "netstat -bn 2>/dev/null | grep -E '%s' | awk '{sum += $(NF-1) + $NF} END {print sum+0}'",
            cursorPattern
        )
        output, status = hs.execute(cursorCmd)
        if status and output then
            cursorBytes = tonumber(output:match("%d+")) or 0
        end
    end

    return claudeBytes, cursorBytes
end

--- CaffBar:getApiTrafficBytes()
--- Method
--- Get total bytes transferred to/from AI APIs (Anthropic + Cursor + Codex)
function obj:getApiTrafficBytes()
    local claudeBytes, cursorBytes = self:getTrafficBytesSeparate()
    return claudeBytes + cursorBytes + self:getCodexTrafficBytes()
end

--- CaffBar:pulseUserActivity()
--- Method
--- Tell macOS the user is active so idle lock/screen saver does not start.
function obj:pulseUserActivity()
    if not self.enabled or self.mode ~= "keepUnlocked" then return end

    local ok, err = pcall(function()
        hs.caffeinate.declareUserActivity()
    end)
    if not ok then
        local logMsg = "[CaffBar] WARN: declareUserActivity failed: " .. tostring(err)
        print(logMsg)
        local f = io.open("/tmp/caffbar.log", "a")
        if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end
    end
end

--- CaffBar:startPreventLockTimer()
--- Method
--- Start periodic user activity assertions for keep-unlocked mode.
function obj:startPreventLockTimer()
    if self.preventLockTimer then return end

    self:pulseUserActivity()
    self.preventLockTimer = hs.timer.doEvery(self.preventLockPulseInterval, function()
        self:pulseUserActivity()
    end)

    local logMsg = "[CaffBar] Prevent-lock timer started"
    print(logMsg)
    local f = io.open("/tmp/caffbar.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end
end

--- CaffBar:stopPreventLockTimer()
--- Method
--- Stop periodic user activity assertions.
function obj:stopPreventLockTimer()
    if self.preventLockTimer then
        self.preventLockTimer:stop()
        self.preventLockTimer = nil

        local logMsg = "[CaffBar] Prevent-lock timer stopped"
        print(logMsg)
        local f = io.open("/tmp/caffbar.log", "a")
        if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end
    end
end

--- CaffBar:startCaffeinate()
--- Method
--- Start caffeinate to prevent sleep. keepUnlocked also prevents display sleep.
function obj:startCaffeinate()
    local targetMode = self.mode == "keepUnlocked" and "keepUnlocked" or "smart"
    if self.isCaffeinateRunning and self.caffeinateMode == targetMode then return end

    if self.isCaffeinateRunning then
        self:stopCaffeinate()
    end

    -- SAFETY: Kill any orphan caffeinate before starting a new one
    -- This prevents multiple caffeinate processes from accumulating
    hs.execute("killall caffeinate 2>/dev/null")

    local args
    if targetMode == "keepUnlocked" then
        -- -d: prevent display sleep, which avoids idle lock caused by display sleep.
        -- -i/-s: keep the system awake while browser/emulator automation runs.
        args = {"-dis"}
    else
        -- -i/-s: prevent idle/system sleep while still allowing display lock.
        args = {"-is"}
    end

    self.caffeinateTask = hs.task.new("/usr/bin/caffeinate", nil, args)
    self.caffeinateTask:start()
    self.isCaffeinateRunning = true
    self.caffeinateMode = targetMode

    local logMsg = string.format("[CaffBar] Caffeinate started (%s mode)", targetMode)
    print(logMsg)
    local f = io.open("/tmp/caffbar.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end
end

--- CaffBar:stopCaffeinate()
--- Method
--- Stop caffeinate to allow system sleep
function obj:stopCaffeinate()
    if not self.isCaffeinateRunning then return end

    if self.caffeinateTask then
        if self.caffeinateTask:isRunning() then
            self.caffeinateTask:terminate()
        end
        self.caffeinateTask = nil
    end
    -- Force kill as backup
    hs.execute("killall caffeinate 2>/dev/null")
    self.isCaffeinateRunning = false
    self.caffeinateMode = nil

    local logMsg = "[CaffBar] Caffeinate stopped (sleep prevention OFF)"
    print(logMsg)
    local f = io.open("/tmp/caffbar.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end
end

--- CaffBar:triggerSleep()
--- Method
--- Trigger system sleep via pmset sleepnow
function obj:triggerSleep()
    -- Get last traffic values for logging
    local claudeStr = self:formatBytes(self._lastClaudeDelta or 0)
    local cursorStr = self:formatBytes(self._lastCursorDelta or 0)
    local codexStr = self:formatBytes(self._lastCodexDelta or 0)
    local thresholdStr = self:formatBytes(self.minTrafficBytes)

    -- Log the event with reason
    local logMsg = string.format("[CaffBar] Auto-sleep: Claude=%s, Cursor=%s, Codex=%s (threshold=%s) → pausing and sleeping",
        claudeStr, cursorStr, codexStr, thresholdStr)
    print(logMsg)
    local f = io.open("/tmp/caffbar.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

    -- Record that WE triggered this sleep
    self.sleepTriggeredByUs = true
    self.lastSleepTime = os.time()
    self.screenLockedTime = self.screenLockedTime or os.time()
    self.preventionDuration = os.time() - self.screenLockedTime

    -- Pause CaffBar (timers and caffeinate stop, but sleepWatcher stays active)
    self:pause()

    -- Small delay to ensure caffeinate is fully dead, then trigger sleep
    hs.timer.doAfter(0.5, function()
        -- Abort if user unlocked screen during the delay
        if not self.isScreenLocked then
            local abortMsg = "[CaffBar] Sleep aborted - screen was unlocked during delay"
            print(abortMsg)
            local af = io.open("/tmp/caffbar.log", "a")
            if af then af:write(os.date("%H:%M:%S ") .. abortMsg .. "\n"); af:close() end
            self.sleepTriggeredByUs = false
            self.sleepTriggerPending = false
            self:start()
            return
        end

        local output = hs.execute("pmset sleepnow 2>&1")
        local logMsg2 = "[CaffBar] pmset sleepnow executed"
        print(logMsg2)
        local f2 = io.open("/tmp/caffbar.log", "a")
        if f2 then f2:write(os.date("%H:%M:%S ") .. logMsg2 .. "\n"); f2:close() end
    end)
end

--- CaffBar:setupSleepWatcher()
--- Method
--- Setup watcher to detect system wake and screen lock events
function obj:setupSleepWatcher()
    local self_ref = self
    self.sleepWatcher = hs.caffeinate.watcher.new(function(eventType)
        -- Log ALL events to file for debugging
        local eventNames = {
            [hs.caffeinate.watcher.systemDidWake] = "systemDidWake",
            [hs.caffeinate.watcher.systemWillSleep] = "systemWillSleep",
            [hs.caffeinate.watcher.systemWillPowerOff] = "systemWillPowerOff",
            [hs.caffeinate.watcher.screensDidSleep] = "screensDidSleep",
            [hs.caffeinate.watcher.screensDidWake] = "screensDidWake",
            [hs.caffeinate.watcher.screensDidLock] = "screensDidLock",
            [hs.caffeinate.watcher.screensDidUnlock] = "screensDidUnlock",
            [hs.caffeinate.watcher.sessionDidResignActive] = "sessionDidResignActive",
            [hs.caffeinate.watcher.sessionDidBecomeActive] = "sessionDidBecomeActive",
        }
        local eventName = eventNames[eventType] or ("unknown:" .. tostring(eventType))
        local logMsg = string.format("[CaffBar] Event: %s", eventName)
        print(logMsg)
        local f = io.open("/tmp/caffbar.log", "a")
        if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

        if eventType == hs.caffeinate.watcher.systemDidWake then
            self_ref:onSystemWake()
        elseif eventType == hs.caffeinate.watcher.screensDidLock then
            self_ref.isScreenLocked = true
            self_ref.screenLockedTime = os.time()  -- record lock time for prevention calc
        elseif eventType == hs.caffeinate.watcher.screensDidUnlock then
            self_ref.isScreenLocked = false
            self_ref.screenLockedTime = nil
            self_ref.consecutiveIdleSeconds = 0  -- reset idle counter on unlock

            -- Safety net: if wake suppression was active, force restart monitoring
            if self_ref.sleepTriggeredByUs then
                local logMsg = "[CaffBar] Screen unlocked while suppressed - force restarting monitoring"
                print(logMsg)
                local f = io.open("/tmp/caffbar.log", "a")
                if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

                self_ref.sleepTriggeredByUs = false
                self_ref.sleepOccurredWhileLocked = false
                self_ref.sleepTriggerPending = false
                self_ref.sleepTriggeredTime = nil
                self_ref.lastSleepTime = nil
                self_ref.preventionDuration = nil
                self_ref.autoWakeSuppressCount = 0

                if not self_ref.enabled then
                    self_ref:start()
                end
            end
        elseif eventType == hs.caffeinate.watcher.screensDidSleep then
            -- Screen turned off (display sleep)
            self_ref.isScreenLocked = true
            -- Set screenLockedTime if not already set (for lock delay calculation)
            if not self_ref.screenLockedTime then
                self_ref.screenLockedTime = os.time()
            end
        elseif eventType == hs.caffeinate.watcher.screensDidWake then
            -- Screen turned on but might still be locked
            -- Don't change isScreenLocked here, wait for screensDidUnlock
        elseif eventType == hs.caffeinate.watcher.systemWillSleep then
            -- Record sleep time if screen is locked (for wake notification)
            if self_ref.isScreenLocked then
                self_ref.sleepOccurredWhileLocked = true
                self_ref.lastSleepTime = os.time()
                -- Calculate prevention time (lock → sleep)
                if self_ref.screenLockedTime then
                    self_ref.preventionDuration = os.time() - self_ref.screenLockedTime
                else
                    self_ref.preventionDuration = 0
                end
            end
        end
    end)
    self.sleepWatcher:start()
    print("[CaffBar] Sleep watcher started")
end

--- CaffBar:formatDuration(seconds)
--- Method
--- Format duration: show seconds if < 1 min, otherwise minutes
function obj:formatDuration(seconds)
    if not seconds or seconds < 0 then
        return "0 sec"
    elseif seconds < 60 then
        return string.format("%d sec", seconds)
    else
        return string.format("%d min", math.floor(seconds / 60))
    end
end

--- CaffBar:getWakeReason()
--- Method
--- Determine if this wake was user-initiated or automatic (Power Nap / DarkWake)
--- Returns: wakeType ("user"|"darkwake"|"unknown"), detail (log excerpt)
function obj:getWakeReason()
    -- Parse recent pmset log for wake events
    local cmd = "pmset -g log 2>/dev/null | grep -E 'DarkWake|Wake from' | tail -3"
    local output, status = hs.execute(cmd)

    if not status or not output or output == "" then
        return "unknown", "no pmset log output"
    end

    -- Get the last line (most recent event)
    local lastLine = nil
    for line in output:gmatch("[^\n]+") do
        lastLine = line
    end

    if not lastLine then
        return "unknown", "no matching log lines"
    end

    -- Check patterns (order matters):
    -- 1) "DarkWake to FullWake" = automatic wake promoted from DarkWake
    if lastLine:match("DarkWake to FullWake") then
        return "darkwake", lastLine
    end

    -- 2) "DarkWake from" = pure DarkWake (Power Nap)
    if lastLine:match("DarkWake from") then
        return "darkwake", lastLine
    end

    -- 3) "Wake from" without "Dark" = user-initiated wake
    if lastLine:match("Wake from") and not lastLine:match("DarkWake") then
        return "user", lastLine
    end

    return "unknown", lastLine
end

--- CaffBar:onSystemWake()
--- Method
--- Handle system wake event - show notification if sleep occurred while screen was locked
function obj:onSystemWake()
    -- If we triggered this sleep, check whether this is a user wake or automatic wake
    if self.sleepTriggeredByUs then
        local wakeType, wakeDetail = self:getWakeReason()

        local logMsg = string.format("[CaffBar] Wake detected (our sleep): type=%s, detail=%s", wakeType, wakeDetail)
        print(logMsg)
        local f = io.open("/tmp/caffbar.log", "a")
        if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

        if wakeType ~= "user" then
            -- Automatic wake (DarkWake/Power Nap or unknown) - suppress caffeinate restart
            -- Keep sleepTriggeredByUs = true so next wake is also checked
            -- Keep sleepOccurredWhileLocked so state is preserved
            -- System will naturally go back to sleep without caffeinate running
            self.consecutiveIdleSeconds = 0
            self.lastSleepTime = os.time()  -- accurate sleep duration for next wake
            self.autoWakeSuppressCount = (self.autoWakeSuppressCount or 0) + 1

            local suppressMsg = string.format("[CaffBar] Suppressing restart (automatic wake: %s, count=%d) - system will re-sleep naturally", wakeType, self.autoWakeSuppressCount)
            print(suppressMsg)
            local sf = io.open("/tmp/caffbar.log", "a")
            if sf then sf:write(os.date("%H:%M:%S ") .. suppressMsg .. "\n"); sf:close() end
            return  -- do NOT restart monitoring
        end

        -- User wake - fall through to normal wake handling
        local userMsg = "[CaffBar] User wake confirmed - proceeding with normal restart"
        print(userMsg)
        local uf = io.open("/tmp/caffbar.log", "a")
        if uf then uf:write(os.date("%H:%M:%S ") .. userMsg .. "\n"); uf:close() end
    end

    -- Show notification if sleep occurred while screen was locked
    if self.sleepOccurredWhileLocked and self.lastSleepTime then
        local sleepDuration = os.time() - self.lastSleepTime
        local preventionDuration = self.preventionDuration or 0

        -- Format durations (show seconds if < 1 min)
        local sleepStr = self:formatDuration(sleepDuration)
        local preventionStr = self:formatDuration(preventionDuration)

        -- Determine reason with more detail
        local reason
        if (self.autoWakeSuppressCount or 0) > 0 then
            reason = string.format("Auto-sleep + %d auto-wakes suppressed", self.autoWakeSuppressCount)
        elseif self.sleepTriggeredByUs then
            reason = string.format("Claude/Cursor/Codex idle for %d min", self.sleepIdleMinutes)
        else
            reason = "System idle timeout"
        end

        -- Log wake event
        local logMsg = string.format("[CaffBar] Woke from sleep (prevented: %s, slept: %s, reason: %s)",
            preventionStr, sleepStr, reason)
        print(logMsg)
        local f = io.open("/tmp/caffbar.log", "a")
        if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

        -- System notification (stays in Notification Center)
        hs.notify.new({
            title = "CaffBar: Sleep Occurred",
            informativeText = string.format(
                "Prevented: %s\nSlept: %s\nReason: %s",
                preventionStr,
                sleepStr,
                reason
            ),
            withdrawAfter = 0  -- Keep in Notification Center
        }):send()

        if self.showAlerts then
            hs.alert.show(string.format("😴 Prevented %s, slept %s", preventionStr, sleepStr), 5)
        end
    end

    -- Reset flags
    self.sleepTriggeredByUs = false
    self.sleepOccurredWhileLocked = false
    self.sleepTriggerPending = false
    self.sleepTriggeredTime = nil  -- reset grace period
    self.lastSleepTime = nil
    self.preventionDuration = nil
    self.consecutiveIdleSeconds = 0
    self.autoWakeSuppressCount = 0

    -- Auto-restart if sleepWatcher is active but monitoring is paused
    if self.sleepWatcher and not self.enabled then
        local logMsg = "[CaffBar] Auto-restarting after wake"
        print(logMsg)
        local f = io.open("/tmp/caffbar.log", "a")
        if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

        self:start()
    end
end

--- CaffBar:checkIdleAndSleep()
--- Method
--- Check if screen is locked and AI tools are idle, trigger sleep if threshold reached
function obj:checkIdleAndSleep()
    if not self.enabled or not self.enableAutoSleep then return end
    if not self.startTime then return end

    -- SAFETY: If system auto-woke without systemDidWake event, reset stale state
    -- This happens when network activity wakes the system but Hammerspoon misses the event
    if self.lastSleepTime and not self.sleepOccurredWhileLocked then
        local timeSinceSleep = os.time() - self.lastSleepTime
        if timeSinceSleep > 300 then  -- 5 minutes - definitely stale
            local logMsg = string.format("[CaffBar] WARN: Detected stale sleep state (%d sec old), resetting", timeSinceSleep)
            print(logMsg)
            local f = io.open("/tmp/caffbar.log", "a")
            if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

            self.lastSleepTime = nil
            self.sleepTriggeredByUs = false
            self.sleepTriggerPending = false
            self.sleepTriggeredTime = nil
        end
    end

    -- Get traffic bytes for Claude and Cursor
    local claudeBytes, cursorBytes = self:getTrafficBytesSeparate()

    -- Calculate Claude delta
    local claudeDelta = 0
    if self.lastClaudeBytes then
        claudeDelta = claudeBytes - self.lastClaudeBytes
        if claudeDelta < 0 then claudeDelta = claudeBytes end
    end
    self.lastClaudeBytes = claudeBytes

    -- Calculate Cursor delta
    local cursorDelta = 0
    if self.lastCursorBytes then
        cursorDelta = cursorBytes - self.lastCursorBytes
        if cursorDelta < 0 then cursorDelta = cursorBytes end
    end
    self.lastCursorBytes = cursorBytes

    -- Calculate Codex delta (per-connection tracking, see getCodexTrafficDelta)
    local codexDelta = self:getCodexTrafficDelta()

    -- Determine activity status (separate thresholds per tool)
    local claudeActive = claudeDelta >= self.minTrafficBytes
    local cursorActive = cursorDelta >= self.minCursorTrafficBytes
    local codexActive = codexDelta >= self.minCodexTrafficBytes

    -- Codex cooldown: real work has quiet stretches (local builds/tests, long
    -- server-side reasoning) and connection closes that read as zero delta.
    -- Keep Codex "active" for codexActiveCooldown after the last traffic burst
    -- so those gaps don't trigger sleep mid-work. maxPreventionMinutes still
    -- bounds total awake time.
    local codexInCooldown = false
    if codexActive then
        self.lastCodexActiveTime = os.time()
    elseif self.lastCodexActiveTime
        and (os.time() - self.lastCodexActiveTime) < self.codexActiveCooldown then
        codexActive = true
        codexInCooldown = true
    end

    -- Check for external "keep awake" marker (e.g., kel pipeline waiting for CI)
    local externalActive = false
    local markerFile = io.open("/tmp/kel-pipeline-active", "r")
    if markerFile then
        markerFile:close()
        externalActive = true
    end

    local isIdle = not claudeActive and not cursorActive and not codexActive and not externalActive

    -- Check max prevention time (force sleep if screen locked too long)
    local maxPreventionExceeded = false
    if self.isScreenLocked and self.screenLockedTime then
        local lockedDuration = os.time() - self.screenLockedTime
        if lockedDuration >= self.maxPreventionMinutes * 60 then
            maxPreventionExceeded = true
        end
    end

    -- DEBUG: Log comparison values
    if self.isScreenLocked then
        local df = io.open("/tmp/caffbar.log", "a")
        if df then
            df:write(os.date("%H:%M:%S ") .. string.format("[DEBUG] cursorDelta=%d, codexDelta=%d, codexActive=%s, cursorActive=%s, isIdle=%s, maxPrevExceeded=%s, extActive=%s\n",
                cursorDelta, codexDelta, tostring(codexActive), tostring(cursorActive), tostring(isIdle), tostring(maxPreventionExceeded), tostring(externalActive)))
            df:close()
        end
    end

    -- Store for sleep trigger logging
    self._lastClaudeDelta = claudeDelta
    self._lastCursorDelta = cursorDelta
    self._lastCodexDelta = codexDelta

    -- Check if we're in grace period after triggering sleep
    local inGracePeriod = false
    if self.sleepTriggeredTime then
        local elapsed = os.time() - self.sleepTriggeredTime
        if elapsed < self.sleepGracePeriod then
            inGracePeriod = true
        else
            -- Grace period expired, reset
            self.sleepTriggeredTime = nil
            self.sleepTriggerPending = false
        end
    end

    -- Update idle counter
    local sleepThresholdSecs = self.sleepIdleMinutes * 60
    if self.isScreenLocked and (isIdle or maxPreventionExceeded) then
        self.consecutiveIdleSeconds = self.consecutiveIdleSeconds + self.idleCheckInterval
    else
        if not inGracePeriod then
            -- Only reset if NOT in grace period
            if self.consecutiveIdleSeconds > 0 then
                local reason = not self.isScreenLocked and "screen unlocked" or "AI active"
                print("[CaffBar] " .. reason .. ", resetting idle counter")
            end
            self.consecutiveIdleSeconds = 0
            self.sleepTriggerPending = false
        end
        -- If in grace period, don't reset - let the sleep attempt complete
    end

    local lockPreventionActive = self.mode == "keepUnlocked"
        and not isIdle
        and not inGracePeriod
        and not maxPreventionExceeded

    if lockPreventionActive then
        self:startPreventLockTimer()
    else
        self:stopPreventLockTimer()
    end

    -- Manage caffeinate: keep ON while screen locked UNTIL idle threshold reached or max prevention exceeded
    -- IMPORTANT: During grace period, don't restart caffeinate to allow sleep to happen
    if inGracePeriod then
        -- During grace period after sleep trigger: keep caffeinate OFF
        self:stopCaffeinate()
    elseif maxPreventionExceeded then
        -- Max prevention time exceeded: stop caffeinate to allow sleep
        self:stopCaffeinate()
    elseif not self.isScreenLocked then
        -- Screen unlocked: caffeinate based on activity only
        if isIdle then
            self:stopCaffeinate()
        else
            self:startCaffeinate()
        end
    else
        -- Screen locked: keep caffeinate ON until we're ready to trigger sleep
        if self.consecutiveIdleSeconds >= sleepThresholdSecs then
            self:stopCaffeinate()  -- allow sleep now
        else
            self:startCaffeinate()  -- keep system awake during idle countdown
        end
    end

    -- Log for debugging (after idle counter update)
    local extraStatus = ""
    if inGracePeriod then
        local remaining = self.sleepGracePeriod - (os.time() - self.sleepTriggeredTime)
        extraStatus = string.format(", GRACE=%ds", remaining)
    end
    if maxPreventionExceeded then
        extraStatus = extraStatus .. ", MAX_PREV_EXCEEDED"
    end
    if externalActive then
        extraStatus = extraStatus .. ", KEL_PIPELINE"
    end
    if lockPreventionActive then
        extraStatus = extraStatus .. ", LOCK_PREVENT"
    end
    if codexInCooldown then
        local cooldownRemaining = self.codexActiveCooldown - (os.time() - self.lastCodexActiveTime)
        extraStatus = extraStatus .. string.format(", CODEX_COOLDOWN=%ds", cooldownRemaining)
    end
    local logMsg = string.format("[CaffBar] Check: screen=%s, Claude=%s, Cursor=%s, Codex=%s, caffeinate=%s, idle=%ds/%ds%s",
        self.isScreenLocked and "LOCKED" or "UNLOCKED",
        self:formatBytes(claudeDelta),
        self:formatBytes(cursorDelta),
        self:formatBytes(codexDelta),
        self.isCaffeinateRunning and "ON" or "OFF",
        self.consecutiveIdleSeconds,
        sleepThresholdSecs,
        extraStatus)
    print(logMsg)
    local f = io.open("/tmp/caffbar.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

    -- Trigger sleep if threshold reached OR max prevention exceeded (only once per cycle)
    local shouldSleep = self.isScreenLocked and self.consecutiveIdleSeconds >= sleepThresholdSecs
        and (isIdle or maxPreventionExceeded)
    if shouldSleep then
        if not self.sleepTriggerPending then
            self.sleepTriggerPending = true
            self:triggerSleep()
        end
    end

    self:updateMenubar()
end

--- CaffBar:start()
--- Method
--- Start smart awake monitoring
function obj:start()
    if self.enabled then return self end

    -- Save original brightness
    if self.enableDimming then
        self.originalBrightness = hs.brightness.get()
    end

    self.startTime = os.time()
    self.lastClaudeBytes = nil
    self.lastCursorBytes = nil
    self.lastCodexConns = nil
    self.lastCodexActiveTime = nil
    self.consecutiveIdleSeconds = 0
    self.sleepTriggeredByUs = false
    self.sleepOccurredWhileLocked = false
    self.sleepTriggerPending = false
    self.sleepTriggeredTime = nil
    self.lastSleepTime = nil
    self.screenLockedTime = nil
    self.preventionDuration = nil
    self.isScreenLocked = false

    -- NOTE: User activity watcher (eventtap) removed for performance
    -- It was causing typing lag by intercepting every keyboard/mouse event
    -- Activity detection is now done purely via API traffic monitoring
    local self_ref = self

    -- Setup sleep/wake watcher
    self:setupSleepWatcher()

    -- Start dim timer
    if self.enableDimming then
        self.dimTimer = hs.timer.doEvery(self.dimInterval, function()
            self_ref:dimScreen()
        end)
    end

    -- Start idle check timer
    if self.enableAutoSleep then
        self.idleCheckTimer = hs.timer.doEvery(self.idleCheckInterval, function()
            local ok, err = pcall(function()
                self_ref:checkIdleAndSleep()
            end)
            if not ok then
                local ef = io.open("/tmp/caffbar.log", "a")
                if ef then ef:write(os.date("%H:%M:%S ") .. "[CaffBar] ERROR: " .. tostring(err) .. "\n"); ef:close() end
            end
        end)
    end

    -- Start DNS refresh timer for Cursor IPs
    self:refreshCursorIPs()  -- refresh now
    self.cursorDnsTimer = hs.timer.doEvery(self.cursorDnsRefreshInterval, function()
        self_ref:refreshCursorIPs()
    end)

    self.enabled = true
    self:updateMenubar()

    print("[CaffBar] Started - monitoring for idle")
    if self.showAlerts then
        local msg
        if self.mode == "keepUnlocked" then
            msg = "🔓 CaffBar ON (smart unlocked)"
        else
            msg = string.format("👁 CaffBar ON (sleep after %dm idle)", self.sleepIdleMinutes)
        end
        hs.alert.show(msg, 2)
    end

    return self
end

--- CaffBar:pause()
--- Method
--- Pause monitoring but keep sleep watcher for auto-restart
function obj:pause()
    if not self.enabled then return self end

    -- Stop prevent-lock timer
    self:stopPreventLockTimer()

    -- Stop caffeinate
    self:stopCaffeinate()

    -- Stop idle check timer
    if self.idleCheckTimer then
        self.idleCheckTimer:stop()
        self.idleCheckTimer = nil
    end

    -- Stop DNS refresh timer
    if self.cursorDnsTimer then
        self.cursorDnsTimer:stop()
        self.cursorDnsTimer = nil
    end

    -- Stop dim timer
    if self.dimTimer then
        self.dimTimer:stop()
        self.dimTimer = nil
    end

    -- Restore brightness
    self:restoreBrightness()

    -- Keep sleepWatcher running for systemDidWake!
    -- Don't stop self.sleepWatcher

    self.startTime = nil
    self.consecutiveIdleSeconds = 0
    self.enabled = false
    self:updateMenubar()

    print("[CaffBar] Paused (sleepWatcher still active)")
    return self
end

--- CaffBar:stop()
--- Method
--- Stop smart awake monitoring
function obj:stop()
    if not self.enabled then return self end

    -- Stop prevent-lock timer
    self:stopPreventLockTimer()

    -- Stop caffeinate
    self:stopCaffeinate()

    -- Stop idle check timer
    if self.idleCheckTimer then
        self.idleCheckTimer:stop()
        self.idleCheckTimer = nil
    end

    -- Stop DNS refresh timer
    if self.cursorDnsTimer then
        self.cursorDnsTimer:stop()
        self.cursorDnsTimer = nil
    end

    -- Stop sleep watcher
    if self.sleepWatcher then
        self.sleepWatcher:stop()
        self.sleepWatcher = nil
    end

    -- Stop dim timer
    if self.dimTimer then
        self.dimTimer:stop()
        self.dimTimer = nil
    end

    -- Restore brightness
    self:restoreBrightness()

    self.startTime = nil
    self.consecutiveIdleSeconds = 0
    self.enabled = false
    self:updateMenubar()

    print("[CaffBar] Stopped")
    if self.showAlerts then
        hs.alert.show("💤 CaffBar OFF", 1)
    end

    return self
end

--- CaffBar:toggle()
--- Method
--- Toggle anti-sleep on/off
function obj:toggle()
    if self.enabled then
        self:stop()
    else
        self:start()
    end
    return self
end

--- CaffBar:isRunning()
--- Method
--- Returns true if anti-sleep is currently active
function obj:isRunning()
    return self.enabled
end

--- CaffBar:bindHotkeys(mapping)
--- Method
--- Bind hotkeys for CaffBar
function obj:bindHotkeys(mapping)
    local def = {
        toggle = function() self:toggle() end
    }
    hs.spoons.bindHotkeysToSpec(def, mapping)
    return self
end

return obj
