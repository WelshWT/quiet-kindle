--[[
Quiet speed: small fixes for time KOReader spends that you can feel, measured on this Kindle (see README).

  - Tailscale plugin: each time a book or the home screen opens, it ran three subprocesses (uname, test,
    pgrep: ~30 ms on this CPU) to learn things that don't change. The CPU type is asked once, and the
    "is the daemon up, start it if not" check runs at most every 10 minutes instead of on every screen.
  - Re-render icons: after a text-size or look change, KOReader re-lays out the rest of the book in the
    background and marks the corner of the page with a small icon until it's done. The work stays, the
    icons go: nothing to read there.
  - Opening a book: no "Opening file '….epub'." box for a book you've opened before (its layout is cached,
    so the page itself appears in about half a second). KOReader showed the box and forced a repaint before
    loading; earlier, making the box invisible instead cost ~250 ms, because an invisible box marks the
    whole screen for redrawing and the e-ink had to finish that before it could draw the book. Here neither
    the box nor the forced repaint happens. A book's first opening (several seconds of layout) still gets
    the box, saying "Opening Pride and Prejudice…" instead of the file name.
]]

local PluginLoader = require("pluginloader")
local logger = require("logger")

local TAILSCALE_RECHECK = 600 -- seconds

local function speedUpTailscale(TS)
    local arch
    local detectArch = TS.detectArch
    if detectArch then
        TS.detectArch = function(self)
            arch = arch or detectArch(self)
            return arch
        end
    end
    local autoStart = TS.autoStartTailscale
    if autoStart then
        local checked_at
        TS.autoStartTailscale = function(self)
            local now = os.time()
            if checked_at and now - checked_at >= 0 and now - checked_at < TAILSCALE_RECHECK then return end
            checked_at = now
            return autoStart(self)
        end
    end
end

local loadPlugins = PluginLoader.loadPlugins
PluginLoader.loadPlugins = function(self)
    local first = self.enabled_plugins == nil
    local enabled, disabled = loadPlugins(self)
    if first then
        for _, plugin in ipairs(enabled or {}) do
            if plugin.name == "tailscale" then
                local ok, err = pcall(speedUpTailscale, plugin)
                if not ok then logger.warn("quiet speed: tailscale patch failed", err) end
            end
        end
    end
    return enabled, disabled
end

local ok, ReaderFlipping = pcall(require, "apps/reader/modules/readerflipping")
if ok and ReaderFlipping then
    ReaderFlipping.rolling_rendering_state_icons = {}
end

local okR, ReaderUI = pcall(require, "apps/reader/readerui")
local okI, InfoMessage = pcall(require, "ui/widget/infomessage")
local okD, DocSettings = pcall(require, "docsettings")
if okR and okI and okD and ReaderUI.showReaderCoroutine then
    local Device = require("device")
    local UIManager = require("ui/uimanager")
    local showReaderCoroutine = ReaderUI.showReaderCoroutine

    -- Home has already closed itself by now ("ShowingReader"), and KOReader quits when nothing is left to
    -- show, so something must stay up until the book is there: this paints nothing and, being invisible,
    -- asks for no refresh when it shows or closes (the box did both).
    local Geom = require("ui/geometry")
    local Widget = require("ui/widget/widget")
    local Placeholder = Widget:extend{ name = "quiet_opening", invisible = true }
    function Placeholder:getSize() return Geom:new{ w = 0, h = 0 } end
    function Placeholder:paintTo() end

    -- Loading a book's cached layout ran ~150 ms slower without the box: the box's e-ink update was what woke
    -- the CPU to full speed (ondemand governor). So the CPU's lowest speed is raised to its highest while the
    -- book loads (switching the governor itself costs ~40 ms; this costs nothing), then put back.
    local CPU = "/sys/devices/system/cpu/cpufreq/policy0/"
    local function readCPU(name)
        local f = io.open(CPU .. name, "r")
        if not f then return nil end
        local v = f:read("*l")
        f:close()
        return v
    end
    local function writeCPU(name, value)
        local f = io.open(CPU .. name, "w")
        if f then
            f:write(value)
            f:close()
        end
    end
    local function boostCPU()
        local min, max = readCPU("scaling_min_freq"), readCPU("scaling_max_freq")
        if not min or not max or min == max then return function() end end
        pcall(writeCPU, "scaling_min_freq", max)
        return function() pcall(writeCPU, "scaling_min_freq", min) end
    end

    -- KOReader's showReaderCoroutine without the box and the forced repaint (same crash handling).
    local function openQuietly(self, file, provider, seamless)
        local holder = Placeholder:new{}
        UIManager:show(holder)
        local unboost = boostCPU()
        UIManager:nextTick(function()
            local co = coroutine.create(function()
                self:doShowReader(file, provider, seamless)
            end)
            local ok, err = coroutine.resume(co)
            if err ~= nil or ok == false then
                io.stderr:write("[!] doShowReader coroutine crashed:\n")
                io.stderr:write(debug.traceback(co, err, 1))
                Device:setIgnoreInput(false)
                Device.input:inhibitInputUntil(0.2)
                UIManager:show(InfoMessage:new{ text = "This book couldn't be opened." })
                self:showFileManager(file)
            end
            unboost()
            UIManager:close(holder)
        end)
    end

    -- Opened before = its sidecar has a reading position (SimpleUI writes empty sidecars for unopened books).
    local function openedBefore(file)
        if not DocSettings:hasSidecarFile(file) then return false end
        local ok, ds = pcall(DocSettings.open, DocSettings, file)
        return ok and ds and (ds:readSetting("last_xpointer") or ds:readSetting("last_page")) ~= nil
    end

    ReaderUI.showReaderCoroutine = function(self, file, provider, seamless)
        local name = type(file) == "string" and file:match("([^/]+)$")
        if seamless or not name then
            return showReaderCoroutine(self, file, provider, seamless)
        end
        if openedBefore(file) then
            return openQuietly(self, file, provider, seamless)
        end
        -- First opening: keep the box, with the title. Kindle Shelf names books "Title - Author.epub".
        name = name:gsub("%.[^.]+$", ""):gsub("%s+%-%s+[^-]+$", "")
        -- the first InfoMessage made from here on is the "Opening file" box
        local raw_new, base_new = rawget(InfoMessage, "new"), InfoMessage.new
        InfoMessage.new = function(cls, o)
            InfoMessage.new = raw_new
            if type(o) == "table" then o.text = "Opening " .. name .. "\u{2026}" end
            return base_new(cls, o)
        end
        local ok, err = pcall(showReaderCoroutine, self, file, provider, seamless)
        InfoMessage.new = raw_new
        if not ok then error(err) end
    end
end
