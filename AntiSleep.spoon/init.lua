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
obj.lastUserActivityTime = nil
obj.userActivityWatcher = nil
obj.sleepWatcher = nil
obj.sleepTriggeredByUs = false
obj.lastSleepTime = nil
obj.sleepOccurredWhileLocked = false  -- track if sleep happened while screen locked
obj.screenLockedTime = nil            -- when screen was locked (for prevention time calc)
obj.preventionDuration = nil          -- how long sleep was prevented (lock → sleep)
obj.sleepTriggerPending = false       -- prevent repeated pmset sleepnow calls
obj.isScreenLocked = false        -- track if screen is locked
obj.caffeinateTask = nil          -- caffeinate process for sleep prevention
obj.isCaffeinateRunning = false   -- track caffeinate state

-- Configuration
obj.showMenubar = true          -- show menubar icon
obj.showAlerts = true           -- show on/off alerts

-- Dimming configuration
obj.enableDimming = true        -- enable gradual dimming
obj.dimStartDelay = 300         -- start dimming after 5 minutes (seconds)
obj.dimInterval = 60            -- dim every 60 seconds
obj.dimStep = 5                 -- reduce brightness by 5% each step
obj.dimMinBrightness = 20       -- minimum brightness (%)

-- Sleep trigger configuration
obj.sleepIdleMinutes = 2        -- trigger sleep after X minutes of combined idle
obj.enableAutoSleep = true      -- enable automatic sleep trigger
obj.idleCheckInterval = 60      -- check idle status every 60 seconds
obj.minTrafficBytes = 1000      -- minimum bytes delta to consider AI "active" (1KB, ignore keep-alive)
obj.userIdleThreshold = 120     -- user idle seconds to consider user "inactive" (2 min)

-- API IP patterns
obj.claudeIpPatterns = {
    "160.79.104",   -- Anthropic (Claude Code)
}
-- Cursor IP patterns (from official domains: *.cursor.sh, *.cursor-cdn.com)
-- These are specific ranges, not broad AWS/Cloudflare
obj.cursorIpPatterns = {
    "100.51",       -- api2.cursor.sh
    "100.52",       -- api2.cursor.sh
    "104.26.8",     -- cursor-cdn.com
    "104.26.9",     -- cursor-cdn.com
    "172.67.71",    -- cursor-cdn.com
    "76.76.21",     -- cursor.sh (Vercel)
}

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
--- Check if user is actively using the computer (based on mouse/keyboard activity)
function obj:isUserActive()
    if not self.lastUserActivityTime then return false end
    local idleTime = os.time() - self.lastUserActivityTime
    return idleTime < self.userIdleThreshold
end

--- AntiSleep:getUserIdleTime()
--- Method
--- Get seconds since last mouse activity
function obj:getUserIdleTime()
    if not self.lastUserActivityTime then return 9999 end
    return os.time() - self.lastUserActivityTime
end

--- AntiSleep:dimScreen()
--- Method
--- Gradually dim the screen (only when both user and Claude are idle)
function obj:dimScreen()
    if not self.enabled or not self.enableDimming then return end
    if not self.startTime then return end

    local elapsed = os.time() - self.startTime
    if elapsed < self.dimStartDelay then return end

    -- If user is active OR there's Claude traffic, restore brightness
    if self:isUserActive() or self.lastTrafficDelta >= self.minTrafficBytes then
        if self.originalBrightness and self.currentBrightness then
            hs.brightness.set(self.originalBrightness)
            self.currentBrightness = nil
        end
        return
    end

    -- Both user and Claude idle, dim the screen
    local currentBrightness = hs.brightness.get()
    if currentBrightness and currentBrightness > self.dimMinBrightness then
        local newBrightness = math.max(currentBrightness - self.dimStep, self.dimMinBrightness)
        hs.brightness.set(newBrightness)
        self.currentBrightness = newBrightness
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
        "netstat -b 2>/dev/null | grep -E '%s' | awk '{sum += $(NF-1) + $NF} END {print sum+0}'",
        claudePattern
    )
    local output, status = hs.execute(claudeCmd)
    if status and output then
        claudeBytes = tonumber(output:match("%d+")) or 0
    end

    -- Get Cursor traffic (bytes via netstat - using specific Cursor domain IPs)
    local cursorPattern = table.concat(self.cursorIpPatterns, "|")
    local cursorCmd = string.format(
        "netstat -b 2>/dev/null | grep -E '%s' | awk '{sum += $(NF-1) + $NF} END {print sum+0}'",
        cursorPattern
    )
    output, status = hs.execute(cursorCmd)
    if status and output then
        cursorBytes = tonumber(output:match("%d+")) or 0
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
    -- Record that WE triggered this sleep
    self.sleepTriggeredByUs = true
    self.lastSleepTime = os.time()

    local sleepTime = os.date("%Y-%m-%d %H:%M:%S")
    local runDuration = math.floor((os.time() - self.startTime) / 60)

    -- Log the event
    local logMsg = string.format("[AntiSleep] Auto-sleep triggered at %s (ran for %d min)", sleepTime, runDuration)
    print(logMsg)
    local f = io.open("/tmp/antisleep.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

    -- Trigger sleep via pmset
    hs.execute("pmset sleepnow")
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

--- AntiSleep:onSystemWake()
--- Method
--- Handle system wake event - show notification if sleep occurred while screen was locked
function obj:onSystemWake()
    -- Show notification if sleep occurred while screen was locked
    if self.sleepOccurredWhileLocked and self.lastSleepTime then
        local sleepDuration = os.time() - self.lastSleepTime
        local sleepMins = math.floor(sleepDuration / 60)
        local preventionMins = math.floor((self.preventionDuration or 0) / 60)

        -- Determine reason
        local reason = self.sleepTriggeredByUs and "Claude/Cursor idle" or "System idle"

        -- Log wake event
        local logMsg = string.format("[AntiSleep] Woke from sleep (prevented: %d min, slept: %d min, reason: %s)",
            preventionMins, sleepMins, reason)
        print(logMsg)
        local f = io.open("/tmp/antisleep.log", "a")
        if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

        -- System notification (stays in Notification Center)
        hs.notify.new({
            title = "AntiSleep: Sleep Occurred",
            informativeText = string.format(
                "Prevented: %d min\nSlept: %d min\nReason: %s",
                preventionMins,
                sleepMins,
                reason
            ),
            withdrawAfter = 0  -- Keep in Notification Center
        }):send()

        if self.showAlerts then
            hs.alert.show(string.format("😴 Prevented %d min, slept %d min", preventionMins, sleepMins), 5)
        end
    end

    -- Reset flags
    self.sleepTriggeredByUs = false
    self.sleepOccurredWhileLocked = false
    self.sleepTriggerPending = false
    self.lastSleepTime = nil
    self.preventionDuration = nil
    self.consecutiveIdleSeconds = 0
end

--- AntiSleep:checkIdleAndSleep()
--- Method
--- Check if screen is locked and AI tools are idle, trigger sleep if threshold reached
function obj:checkIdleAndSleep()
    if not self.enabled or not self.enableAutoSleep then return end
    if not self.startTime then return end

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

    -- Determine activity status (either one active = not idle)
    local claudeActive = claudeDelta >= self.minTrafficBytes
    local cursorActive = cursorDelta >= self.minTrafficBytes
    local isIdle = not claudeActive and not cursorActive

    -- Update idle counter
    local sleepThresholdSecs = self.sleepIdleMinutes * 60
    if self.isScreenLocked and isIdle then
        self.consecutiveIdleSeconds = self.consecutiveIdleSeconds + self.idleCheckInterval
    else
        if self.consecutiveIdleSeconds > 0 then
            local reason = not self.isScreenLocked and "screen unlocked" or "AI active"
            print("[AntiSleep] " .. reason .. ", resetting idle counter")
        end
        self.consecutiveIdleSeconds = 0
        self.sleepTriggerPending = false  -- reset so sleep can be triggered again
    end

    -- Manage caffeinate: keep ON while screen locked UNTIL idle threshold reached
    -- This prevents macOS from sleeping immediately when traffic temporarily drops
    if not self.isScreenLocked then
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
            self:startCaffeinate()  -- keep system awake during grace period
        end
    end

    -- Log for debugging (after idle counter update)
    local logMsg = string.format("[AntiSleep] Check: screen=%s, Claude=%s, Cursor=%s, caffeinate=%s, idle=%ds/%ds",
        self.isScreenLocked and "LOCKED" or "UNLOCKED",
        self:formatBytes(claudeDelta),
        self:formatBytes(cursorDelta),
        self.isCaffeinateRunning and "ON" or "OFF",
        self.consecutiveIdleSeconds,
        sleepThresholdSecs)
    print(logMsg)
    local f = io.open("/tmp/antisleep.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

    -- Trigger sleep if threshold reached (only once per cycle)
    if self.isScreenLocked and isIdle and self.consecutiveIdleSeconds >= sleepThresholdSecs then
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
    self.lastUserActivityTime = os.time()
    self.sleepTriggeredByUs = false
    self.sleepOccurredWhileLocked = false
    self.sleepTriggerPending = false
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
            self_ref:checkIdleAndSleep()
        end)
    end

    self.enabled = true
    self:updateMenubar()

    print("[AntiSleep] Started - monitoring for idle")
    if self.showAlerts then
        local msg = string.format("👁 AntiSleep ON (sleep after %dm idle)", self.sleepIdleMinutes)
        hs.alert.show(msg, 2)
    end

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

    -- Stop user activity watcher
    if self.userActivityWatcher then
        self.userActivityWatcher:stop()
        self.userActivityWatcher = nil
    end
    self.lastUserActivityTime = nil

    -- Restore brightness
    self:restoreBrightness()

    self.startTime = nil
    self.lastTotalBytes = 0
    self.lastTrafficDelta = 0
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
