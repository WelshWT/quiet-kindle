--[[
Quiet sleep screens (quiet.koplugin/quiet_sleep.lua) and waking up where you were. Asked for: "better options for
sleeping screen ... no matter where i am, unsleep should just pick up where i left off, performantly".

  - KOReader's screensaver setup runs as before, then is handed our image as a "cover" with no message. Its own show
    (portrait rotation, dithering, the full refresh), close and clean-up do the rest, the same for every way the
    Kindle sleeps: power button, cover, auto-sleep.
  - Our image isn't an "image mode" for the flash in front of it: KOReader flashes the screen white before an image
    screensaver to fight ghosting; ours goes straight to the image in its one full refresh (one flash, not two, and no
    white blink before the frost).
  - Power off and reboot keep KOReader's own message; a book marked "exclude from screensaver" keeps KOReader's rule.
  - The CPU runs at full speed for the second it takes (below): the Kindle idles at under a third of it.
  - Waking: SimpleUI reopens Home on every wake when KOReader starts on Home, through its resume handler and through
    its handling of full-screen windows (the sleep screen is one: Home was closed under it and rebuilt cold on wake).
    Quiet keeps "start with Home" for starting KOReader: waking leaves you where you were (the Library on its page,
    Stats, Home without a rebuild, the book). SimpleUI's own "Return to Home Screen on Wakeup", if it is ever turned
    on, still works.
]]

local Screensaver = require("ui/screensaver")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local userpatch = require("userpatch")

-- Making and drawing the sleep screen is ~0.25 s of work at the CPU's idle speed (measured from a press while idle:
-- the image 89 ms, drawing it ~170 ms, before the panel even starts): the Kindle idles at 600 MHz of 2 GHz, and a
-- press of the power button doesn't speed it up first. As for opening a book (2-quiet-speed.lua), the CPU's lowest
-- speed is raised to its highest for that and put back a second later. /tmp/quiet-sleep-cpu keeps the old lowest
-- speed until then, so a KOReader that stops in between puts it back when it starts again.
local CPU = "/sys/devices/system/cpu/cpufreq/policy0/"
local CPU_MARK = "/tmp/quiet-sleep-cpu"

local function readLine(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*l")
    f:close()
    return v
end

local function writeLine(path, value)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(value)
    f:close()
    return true
end

local function unboostCPU()
    local min = readLine(CPU_MARK)
    if not min then return end
    writeLine(CPU .. "scaling_min_freq", min)
    os.remove(CPU_MARK)
end

local function boostCPU()
    if readLine(CPU_MARK) then return end -- still raised from a sleep a moment ago
    local min, max = readLine(CPU .. "scaling_min_freq"), readLine(CPU .. "scaling_max_freq")
    if not min or not max or min == max then return end -- unknown, or raised by someone else (a book opening)
    if writeLine(CPU_MARK, min) then writeLine(CPU .. "scaling_min_freq", max) end
end

pcall(unboostCPU)

if not Screensaver._quiet_sleep then
    Screensaver._quiet_sleep = true
    local setup, modeIsImage, cleanup = Screensaver.setup, Screensaver.modeIsImage, Screensaver.cleanup

    function Screensaver:setup(event, event_message)
        pcall(boostCPU)
        UIManager:scheduleIn(1, function() pcall(unboostCPU) end)
        setup(self, event, event_message)
        self._quiet = nil
        if event or not self.ui then return end
        if self.ui.document and self.ui.doc_settings and self.ui.doc_settings:isTrue("exclude_screensaver") then
            return
        end
        local ok, Sleep = pcall(require, "quiet_sleep")
        if not ok or type(Sleep) ~= "table" then
            logger.warn("quiet sleep: unavailable:", Sleep)
            return
        end
        local ok2, bb = pcall(Sleep.image, self.ui)
        if not ok2 or not bb then
            logger.warn("quiet sleep: no image:", bb)
            return
        end
        if self.image then self.image:free() end
        self.image, self.image_file = bb, nil
        self.screensaver_type = "cover"
        self.show_message, self.overlay_message = false, nil
        self.screensaver_background = "none"
        self._quiet = true
    end

    function Screensaver:modeIsImage()
        if self._quiet then return false end
        return modeIsImage(self)
    end

    function Screensaver:cleanup(...)
        self._quiet = nil
        return cleanup(self, ...)
    end
end

-- The sleep screen is an overlay to SimpleUI, not a window you go to. SimpleUI closes Home whenever a named full-screen
-- window opens over it, and goes back to Home (rebuilding it from scratch) whenever one closes; for the sleep screen
-- that threw Home away on every sleep, rebuilt it on every wake, and put you on Home from the Library or Stats. Its own
-- flags say no to both: Home stays alive under the sleep screen, and closing it navigates nowhere. Set on the classes,
-- so every sleep screen has them, KOReader's own included.
for _, name in ipairs({ "ui/widget/screensaverwidget", "ui/widget/screensaverlockwidget" }) do
    local ok, class = pcall(require, name)
    if ok and type(class) == "table" then
        class._sui_keep_homescreen = true
        class._navbar_closing_intentionally = true
    end
end

userpatch.registerPatchPluginFunc("simpleui", function()
    local ok, Patches = pcall(require, "infra/sui_patches")
    if not ok or type(Patches) ~= "table" or type(Patches.showHSAfterResume) ~= "function" or Patches._quiet_wake then
        return
    end
    Patches._quiet_wake = true
    local showHSAfterResume = Patches.showHSAfterResume
    Patches.showHSAfterResume = function(plugin, force)
        if force then return showHSAfterResume(plugin, force) end
    end
end)
