--- === AntiSleep ===
---
--- Prevents macOS from sleeping using caffeinate + keystroke simulation.
--- Useful for bypassing MDM idle detection.
---
--- Features:
---   - Caffeinate integration (prevents sleep)
---   - Keystroke simulation (bypasses idle detection)
---   - Gradual screen dimming (saves power, looks natural)
---   - Traffic-based auto stop (stops when Claude Code is idle)

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
obj.caffeinateTask = nil
obj.keystrokeTimer = nil
obj.dimTimer = nil
obj.trafficCheckTimer = nil
obj.menubar = nil
obj.originalBrightness = nil
obj.currentBrightness = nil
obj.startTime = nil
obj.lastTotalBytes = 0
obj.lastTrafficDelta = 0
obj.idleCheckCount = 0
obj.lastUserActivityTime = nil
obj.userActivityWatcher = nil

-- Configuration
obj.keystrokeInterval = 60      -- seconds between keystrokes
obj.showMenubar = true          -- show menubar icon
obj.showAlerts = true           -- show on/off alerts

-- Dimming configuration
obj.enableDimming = true        -- enable gradual dimming
obj.dimStartDelay = 300         -- start dimming after 5 minutes (seconds)
obj.dimInterval = 60            -- dim every 60 seconds
obj.dimStep = 5                 -- reduce brightness by 5% each step
obj.dimMinBrightness = 20       -- minimum brightness (%)

-- Traffic monitoring configuration
obj.enableTrafficWatch = true   -- enable traffic-based auto stop
obj.trafficGracePeriod = 60     -- grace period before checking traffic (1 min for testing)
obj.trafficCheckInterval = 60   -- check traffic every 60 seconds
obj.idleThreshold = 2           -- stop after N consecutive idle checks
obj.minTrafficBytes = 100       -- minimum bytes delta to consider "active"
obj.userIdleThreshold = 120     -- user idle seconds to consider "inactive" (2 min)

-- Anthropic API IP pattern
obj.anthropicIpPattern = "160.79.104"

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
    print("[AntiSleep] Initialized (orphan caffeinate cleaned)")
    return self
end

--- AntiSleep:formatBytes(bytes)
--- Method
--- Format bytes to human readable string
function obj:formatBytes(bytes)
    if bytes < 1024 then
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

            if self.enableTrafficWatch then
                local graceRemaining = self.trafficGracePeriod - secs
                if graceRemaining > 0 then
                    status = string.format("\nGrace: %dm left", math.ceil(graceRemaining / 60))
                else
                    status = string.format("\nLast: %s/min (idle: %d/%d)",
                        self:formatBytes(self.lastTrafficDelta),
                        self.idleCheckCount,
                        self.idleThreshold)
                end
            end
        end
        self.menubar:setTitle("☕")
        tooltip = tooltip .. "ON" .. elapsed .. " (click to toggle)" .. status
    else
        self.menubar:setTitle("💤")
        tooltip = tooltip .. "OFF (click to toggle)"
    end

    self.menubar:setTooltip(tooltip)
end

--- AntiSleep:simulateKeystroke()
--- Method
--- Simulate a keystroke to prevent idle detection
function obj:simulateKeystroke()
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.shift, true):post()
    hs.timer.usleep(50000)
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.shift, false):post()
end

--- AntiSleep:isUserActive()
--- Method
--- Check if user is actively using the computer (based on mouse activity only)
--- Note: We track mouse only because we simulate keyboard, so hs.host.idleTime() won't work
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

--- AntiSleep:getAnthropicTrafficBytes()
--- Method
--- Get total bytes transferred to/from Anthropic API using netstat -b
function obj:getAnthropicTrafficBytes()
    -- netstat -b shows: ... recv_bytes send_bytes (last two columns)
    -- Filter for Anthropic API IP (160.79.104.*)
    local cmd = string.format(
        "netstat -b 2>/dev/null | grep '%s' | awk '{sum += $(NF-1) + $NF} END {print sum+0}'",
        self.anthropicIpPattern
    )

    local output, status = hs.execute(cmd)
    if status and output then
        local bytes = tonumber(output:match("%d+")) or 0
        return bytes
    end

    return 0
end

--- AntiSleep:checkTraffic()
--- Method
--- Check if there's Claude Code traffic, stop if idle
function obj:checkTraffic()
    if not self.enabled or not self.enableTrafficWatch then return end
    if not self.startTime then return end

    local elapsed = os.time() - self.startTime

    -- Still in grace period
    if elapsed < self.trafficGracePeriod then
        self:updateMenubar()
        return
    end

    -- Get current total bytes from Anthropic API connections
    local currentBytes = self:getAnthropicTrafficBytes()
    local delta = 0

    if self.lastTotalBytes > 0 then
        delta = currentBytes - self.lastTotalBytes
        -- Handle counter reset (new connections replace old ones)
        if delta < 0 then
            delta = currentBytes
        end
    end

    self.lastTotalBytes = currentBytes
    self.lastTrafficDelta = delta

    -- Check user activity (mouse-based, not hs.host.idleTime which our keystrokes reset)
    local userIdle = self:getUserIdleTime()
    local userActive = self:isUserActive()

    -- Log for debugging (print to console and file)
    local logMsg = string.format("[AntiSleep] Traffic check: total=%d, delta=%d, idle=%d/%d, user=%ds",
        currentBytes, delta, self.idleCheckCount, self.idleThreshold, math.floor(userIdle))
    print(logMsg)
    local f = io.open("/tmp/antisleep.log", "a")
    if f then f:write(os.date("%H:%M:%S ") .. logMsg .. "\n"); f:close() end

    if delta >= self.minTrafficBytes or userActive then
        -- Active traffic OR user active, reset idle counter
        self.idleCheckCount = 0
        self:updateMenubar()
    else
        -- No traffic AND user idle, increment idle counter
        self.idleCheckCount = self.idleCheckCount + 1

        if self.idleCheckCount >= self.idleThreshold then
            -- Idle for too long, stop
            local stopTime = os.date("%Y-%m-%d %H:%M:%S")
            local runDuration = math.floor((os.time() - self.startTime) / 60)
            local logMsg = string.format("AntiSleep auto-stopped at %s (ran for %d min)", stopTime, runDuration)
            print("[AntiSleep] " .. logMsg)

            -- System notification (stays in Notification Center)
            hs.notify.new({
                title = "AntiSleep Auto-Stopped",
                informativeText = string.format("Stopped: %s\nRan for: %d minutes\nReason: No Claude traffic", stopTime, runDuration),
                withdrawAfter = 0  -- Don't auto-dismiss, keep in Notification Center
            }):send()

            if self.showAlerts then
                hs.alert.show("😴 AntiSleep stopped - " .. stopTime, 3)
            end
            self:stop()
        else
            self:updateMenubar()
        end
    end
end

--- AntiSleep:start()
--- Method
--- Start anti-sleep protection
function obj:start()
    if self.enabled then return self end

    -- Save original brightness
    if self.enableDimming then
        self.originalBrightness = hs.brightness.get()
    end

    self.startTime = os.time()
    self.lastTotalBytes = 0
    self.lastTrafficDelta = 0
    self.idleCheckCount = 0
    self.lastUserActivityTime = os.time()

    -- Start mouse activity watcher (keyboard excluded because we simulate it)
    local self_ref = self
    self.userActivityWatcher = hs.eventtap.new({
        hs.eventtap.event.types.mouseMoved,
        hs.eventtap.event.types.leftMouseDown,
        hs.eventtap.event.types.rightMouseDown,
        hs.eventtap.event.types.scrollWheel
    }, function(event)
        self_ref.lastUserActivityTime = os.time()
        return false  -- don't consume the event
    end)
    self.userActivityWatcher:start()

    -- Start caffeinate
    self.caffeinateTask = hs.task.new("/usr/bin/caffeinate", nil, {"-dims"})
    self.caffeinateTask:start()

    -- Start keystroke timer
    local self_ref = self
    self.keystrokeTimer = hs.timer.doEvery(self.keystrokeInterval, function()
        self_ref:simulateKeystroke()
        self_ref:updateMenubar()
    end)

    -- Start dim timer
    if self.enableDimming then
        self.dimTimer = hs.timer.doEvery(self.dimInterval, function()
            self_ref:dimScreen()
        end)
    end

    -- Start traffic check timer
    if self.enableTrafficWatch then
        self.trafficCheckTimer = hs.timer.doEvery(self.trafficCheckInterval, function()
            self_ref:checkTraffic()
        end)
    end

    self.enabled = true
    self:updateMenubar()

    print("[AntiSleep] Started")
    if self.showAlerts then
        local msg = "☕ AntiSleep ON"
        if self.enableTrafficWatch then
            msg = msg .. string.format(" (grace: %dm)", self.trafficGracePeriod / 60)
        end
        hs.alert.show(msg, 2)
    end

    return self
end

--- AntiSleep:stop()
--- Method
--- Stop anti-sleep protection
function obj:stop()
    if not self.enabled then return self end

    -- Stop caffeinate (use killall as backup since terminate() may not work)
    if self.caffeinateTask then
        if self.caffeinateTask:isRunning() then
            self.caffeinateTask:terminate()
        end
        self.caffeinateTask = nil
    end
    -- Force kill any remaining caffeinate started by us
    hs.execute("killall caffeinate 2>/dev/null")

    -- Stop keystroke timer
    if self.keystrokeTimer then
        self.keystrokeTimer:stop()
        self.keystrokeTimer = nil
    end

    -- Stop dim timer
    if self.dimTimer then
        self.dimTimer:stop()
        self.dimTimer = nil
    end

    -- Stop traffic check timer
    if self.trafficCheckTimer then
        self.trafficCheckTimer:stop()
        self.trafficCheckTimer = nil
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
    self.idleCheckCount = 0
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
