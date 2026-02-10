--- === AntiSleep ===
---
--- Smart sleep management for Claude Code sessions.
--- Monitors user activity + Claude API traffic, triggers sleep when both are idle.
---
--- Features:
---   - Traffic-based auto sleep (sleeps when both user and Claude are idle)
---   - Wake notification (shows when auto-sleep occurred)
---   - Gradual screen dimming (saves power while waiting)

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "AntiSleep"
obj.version = "1.4.0"
obj.author = "Your Name"
obj.license = "MIT"
obj.homepage = "https://github.com/yourusername/AntiSleep.spoon"

-- Internal state
obj.enabled = false
obj.dimTimer = nil
obj.idleCheckTimer = nil
obj.menubar = nil
obj.originalBrightness = nil
obj.currentBrightness = nil
obj.startTime = nil
obj.lastClaudeBytes = nil         -- for Claude delta calculation
obj.lastCursorBytes = nil         -- for Cursor delta calculation
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

-- Configuration
obj.showMenubar = true          -- show menubar icon
obj.showAlerts = true           -- show on/off alerts

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

--- AntiSleep:refreshCursorIPs()
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
    local logMsg = string.format("[AntiSleep] Cursor IPs: %s", table.concat(patterns, ", "))
    print(logMsg)
    local f = io.open("/tmp/antisleep.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end
end

--- AntiSleep:init()
--- Method
--- Initialize the Spoon
function obj:init()
    -- SAFETY: Kill any orphan caffeinate from previous sessions
    hs.execute("killall caffeinate 2>/dev/null")

    if self.showMenubar then
        self.menubar = hs.menubar.new()
        if self.menubar then
            self.menubar:setClickCallback(function() self:toggle() end)
        end
    end
    self:updateMenubar()
    print("[AntiSleep] Initialized")
    return self
end

--- AntiSleep:formatBytes(bytes)
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

--- AntiSleep:updateMenubar()
--- Method
--- Update menubar icon and tooltip
function obj:updateMenubar()
    if not self.menubar then return end

    local tooltip = "AntiSleep: "
    if self.enabled then
        local elapsed = ""
        local status = ""
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
        self.menubar:setTitle("👁")
        tooltip = tooltip .. "Monitoring" .. elapsed .. status
    else
        self.menubar:setTitle("💤")
        tooltip = tooltip .. "OFF (click to toggle)"
    end

    self.menubar:setTooltip(tooltip)
end

--- AntiSleep:isUserActive()
--- Method
--- Check if user is actively using the computer (based on system idle time)
function obj:isUserActive()
    local idleTime = hs.host.idleTime()  -- system idle time in seconds
    return idleTime < self.userIdleThreshold
end

--- AntiSleep:getUserIdleTime()
--- Method
--- Get seconds since last user activity
function obj:getUserIdleTime()
    return hs.host.idleTime()
end

--- AntiSleep:dimScreen()
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
            local logMsg = string.format("[AntiSleep] Dim: restored (userIdle=%.0fs < %ds)", idleTime, self.userIdleThreshold)
            print(logMsg)
            local f = io.open("/tmp/antisleep.log", "a")
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
        local logMsg = string.format("[AntiSleep] Dim: %d%% -> %d%% (userIdle=%.0fs)", currentBrightness, newBrightness, idleTime)
        print(logMsg)
        local f = io.open("/tmp/antisleep.log", "a")
        if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end
    end
end

--- AntiSleep:restoreBrightness()
--- Method
--- Restore original screen brightness
function obj:restoreBrightness()
    if self.originalBrightness then
        hs.brightness.set(self.originalBrightness)
        self.originalBrightness = nil
        self.currentBrightness = nil
    end
end

--- AntiSleep:getTrafficBytesSeparate()
--- Method
--- Get bytes transferred separately for Claude and Cursor
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

--- AntiSleep:getApiTrafficBytes()
--- Method
--- Get total bytes transferred to/from AI APIs (Anthropic + Cursor) using netstat -b
function obj:getApiTrafficBytes()
    local claudeBytes, cursorBytes = self:getTrafficBytesSeparate()
    return claudeBytes + cursorBytes
end

--- AntiSleep:startCaffeinate()
--- Method
--- Start caffeinate to prevent idle system sleep (but allow display sleep for Lock)
function obj:startCaffeinate()
    if self.isCaffeinateRunning then return end

    -- SAFETY: Kill any orphan caffeinate before starting a new one
    -- This prevents multiple caffeinate processes from accumulating
    hs.execute("killall caffeinate 2>/dev/null")

    -- -is: prevent idle sleep AND system sleep (including lid close)
    -- Display sleep still allowed (screen lock works)
    self.caffeinateTask = hs.task.new("/usr/bin/caffeinate", nil, {"-is"})
    self.caffeinateTask:start()
    self.isCaffeinateRunning = true

    local logMsg = "[AntiSleep] Caffeinate started (sleep prevention ON)"
    print(logMsg)
    local f = io.open("/tmp/antisleep.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end
end

--- AntiSleep:stopCaffeinate()
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

    local logMsg = "[AntiSleep] Caffeinate stopped (sleep prevention OFF)"
    print(logMsg)
    local f = io.open("/tmp/antisleep.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end
end

--- AntiSleep:triggerSleep()
--- Method
--- Trigger system sleep via pmset sleepnow
function obj:triggerSleep()
    -- Get last traffic values for logging
    local claudeStr = self:formatBytes(self._lastClaudeDelta or 0)
    local cursorStr = self:formatBytes(self._lastCursorDelta or 0)
    local thresholdStr = self:formatBytes(self.minTrafficBytes)

    -- Log the event with reason
    local logMsg = string.format("[AntiSleep] Auto-sleep: Claude=%s, Cursor=%s (threshold=%s) → pausing and sleeping",
        claudeStr, cursorStr, thresholdStr)
    print(logMsg)
    local f = io.open("/tmp/antisleep.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

    -- Record that WE triggered this sleep
    self.sleepTriggeredByUs = true
    self.lastSleepTime = os.time()
    self.screenLockedTime = self.screenLockedTime or os.time()
    self.preventionDuration = os.time() - self.screenLockedTime

    -- Pause AntiSleep (timers and caffeinate stop, but sleepWatcher stays active)
    self:pause()

    -- Small delay to ensure caffeinate is fully dead, then trigger sleep
    hs.timer.doAfter(0.5, function()
        local output = hs.execute("pmset sleepnow 2>&1")
        local logMsg2 = "[AntiSleep] pmset sleepnow executed"
        print(logMsg2)
        local f2 = io.open("/tmp/antisleep.log", "a")
        if f2 then f2:write(os.date("%H:%M:%S ") .. logMsg2 .. "\n"); f2:close() end
    end)
end

--- AntiSleep:setupSleepWatcher()
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
        local logMsg = string.format("[AntiSleep] Event: %s", eventName)
        print(logMsg)
        local f = io.open("/tmp/antisleep.log", "a")
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
    print("[AntiSleep] Sleep watcher started")
end

--- AntiSleep:formatDuration(seconds)
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

--- AntiSleep:onSystemWake()
--- Method
--- Handle system wake event - show notification if sleep occurred while screen was locked
function obj:onSystemWake()
    -- Show notification if sleep occurred while screen was locked
    if self.sleepOccurredWhileLocked and self.lastSleepTime then
        local sleepDuration = os.time() - self.lastSleepTime
        local preventionDuration = self.preventionDuration or 0

        -- Format durations (show seconds if < 1 min)
        local sleepStr = self:formatDuration(sleepDuration)
        local preventionStr = self:formatDuration(preventionDuration)

        -- Determine reason with more detail
        local reason
        if self.sleepTriggeredByUs then
            reason = string.format("Claude/Cursor idle for %d min", self.sleepIdleMinutes)
        else
            reason = "System idle timeout"
        end

        -- Log wake event
        local logMsg = string.format("[AntiSleep] Woke from sleep (prevented: %s, slept: %s, reason: %s)",
            preventionStr, sleepStr, reason)
        print(logMsg)
        local f = io.open("/tmp/antisleep.log", "a")
        if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

        -- System notification (stays in Notification Center)
        hs.notify.new({
            title = "AntiSleep: Sleep Occurred",
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

    -- Auto-restart if sleepWatcher is active but monitoring is paused
    if self.sleepWatcher and not self.enabled then
        local logMsg = "[AntiSleep] Auto-restarting after wake"
        print(logMsg)
        local f = io.open("/tmp/antisleep.log", "a")
        if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

        self:start()
    end
end

--- AntiSleep:checkIdleAndSleep()
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
            local logMsg = string.format("[AntiSleep] WARN: Detected stale sleep state (%d sec old), resetting", timeSinceSleep)
            print(logMsg)
            local f = io.open("/tmp/antisleep.log", "a")
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

    -- Determine activity status (separate thresholds for Claude vs Cursor)
    local claudeActive = claudeDelta >= self.minTrafficBytes
    local cursorActive = cursorDelta >= self.minCursorTrafficBytes
    local isIdle = not claudeActive and not cursorActive

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
        local df = io.open("/tmp/antisleep.log", "a")
        if df then
            df:write(os.date("%H:%M:%S ") .. string.format("[DEBUG] cursorDelta=%d, threshold=%d, cursorActive=%s, isIdle=%s, maxPrevExceeded=%s\n",
                cursorDelta, self.minCursorTrafficBytes, tostring(cursorActive), tostring(isIdle), tostring(maxPreventionExceeded)))
            df:close()
        end
    end

    -- Store for sleep trigger logging
    self._lastClaudeDelta = claudeDelta
    self._lastCursorDelta = cursorDelta

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
                print("[AntiSleep] " .. reason .. ", resetting idle counter")
            end
            self.consecutiveIdleSeconds = 0
            self.sleepTriggerPending = false
        end
        -- If in grace period, don't reset - let the sleep attempt complete
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
    local logMsg = string.format("[AntiSleep] Check: screen=%s, Claude=%s, Cursor=%s, caffeinate=%s, idle=%ds/%ds%s",
        self.isScreenLocked and "LOCKED" or "UNLOCKED",
        self:formatBytes(claudeDelta),
        self:formatBytes(cursorDelta),
        self.isCaffeinateRunning and "ON" or "OFF",
        self.consecutiveIdleSeconds,
        sleepThresholdSecs,
        extraStatus)
    print(logMsg)
    local f = io.open("/tmp/antisleep.log", "a")
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

--- AntiSleep:start()
--- Method
--- Start smart sleep monitoring
function obj:start()
    if self.enabled then return self end

    -- Save original brightness
    if self.enableDimming then
        self.originalBrightness = hs.brightness.get()
    end

    self.startTime = os.time()
    self.lastClaudeBytes = nil
    self.lastCursorBytes = nil
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
                local ef = io.open("/tmp/antisleep.log", "a")
                if ef then ef:write(os.date("%H:%M:%S ") .. "[AntiSleep] ERROR: " .. tostring(err) .. "\n"); ef:close() end
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

    print("[AntiSleep] Started - monitoring for idle")
    if self.showAlerts then
        local msg = string.format("👁 AntiSleep ON (sleep after %dm idle)", self.sleepIdleMinutes)
        hs.alert.show(msg, 2)
    end

    return self
end

--- AntiSleep:pause()
--- Method
--- Pause monitoring but keep sleep watcher for auto-restart
function obj:pause()
    if not self.enabled then return self end

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

    print("[AntiSleep] Paused (sleepWatcher still active)")
    return self
end

--- AntiSleep:stop()
--- Method
--- Stop smart sleep monitoring
function obj:stop()
    if not self.enabled then return self end

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

    print("[AntiSleep] Stopped")
    if self.showAlerts then
        hs.alert.show("💤 AntiSleep OFF", 1)
    end

    return self
end

--- AntiSleep:toggle()
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

--- AntiSleep:isRunning()
--- Method
--- Returns true if anti-sleep is currently active
function obj:isRunning()
    return self.enabled
end

--- AntiSleep:bindHotkeys(mapping)
--- Method
--- Bind hotkeys for AntiSleep
function obj:bindHotkeys(mapping)
    local def = {
        toggle = function() self:toggle() end
    }
    hs.spoons.bindHotkeysToSpec(def, mapping)
    return self
end

return obj
