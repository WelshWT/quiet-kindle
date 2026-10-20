--[[
Quiet light: the front light follows the room, smoothly, and learns from you.
Design and research: "Automatic light" in docs/design.md.

  - The light sensor (TI OPT3001) is read directly, down to 0.01 lux. Amazon's daemon (powerd) is told to stop
    its own automatic light while KOReader runs; that also switches the sensor off, so it's switched back on here
    with the sensor's enable call (_IOW('A', 2, int) = 1 on /dev/als). powerd only acts on the sensor when it
    switched it on itself, so it leaves the light alone.
  - Shadow-proof: it goes by the brightest reading of the last 4 s, and changes only once a new light level has
    held for 2 s (room got brighter) or 6 s (darker), and moved at least 25% from where it last set the light
    (Android's AutomaticBrightnessController does the same).
  - Curve: the levels Amazon's own auto light chose on this Kindle, smoothed (monotone cubic in log lux) with a darker floor
    for a pitch-black room; off above 6000 lux, where a front light adds nothing.
  - Learning: changing the brightness while Auto is on is a preference at that light. The curve bends through
    it (kernel regression, sigma 0.4 decades: half as much at 3x or 1/3 of the light), averaged with earlier
    ones (half-life 45 days); and what you set holds until the room light moves by more than 60% (Android's
    short-term model).
  - Cheap: a reading on touches (at most every 2 s) and every 10 s otherwise, nothing while the Kindle sleeps.
  - Amazon's own Auto is stopped whenever KOReader runs (also with this Auto off, so "off" means manual) and put
    back when KOReader exits (patches/8-quiet-exit.lua), or by a small watcher if KOReader crashes or is killed.
    If it can't be stopped, this Auto stays idle until KOReader's next start rather than fight it for the light.
  - Its own steps are the only changes it makes: a hand change (or KOReader putting the light back after sleep)
    stops a fade at once, and nothing runs while the Kindle goes to sleep.

The Light sheet's Auto switch: require("quiet_autolight").setOn(true/false). State for debugging over SSH:
bin/kcmd 'lua return require("quiet_autolight").debug()'.
]]

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")

if not (Device:isKindle() and Device:hasFrontlight()) then return end
local SENSOR = "/sys/bus/iio/devices/iio:device1/in_illuminance_input"
do
    local f = io.open(SENSOR)
    if not f then return end
    f:close()
end

local ffi = require("ffi")
require("ffi/posix_h")
local O_RDWR, ALS_ENABLE = 2, 0x40044102

local L = {}
package.loaded["quiet_autolight"] = L

-- Amazon's table on this Kindle (lux band centre -> level), smoothed, plus a darker floor below 1 lux.
local BASE = { { 0.3, 5 }, { 10, 7 }, { 24.5, 7 }, { 53, 9 }, { 102, 13 }, { 212, 13 }, { 424, 15 }, { 735, 19 },
    { 1162, 22 }, { 2598, 18 }, { 6000, 0 } }
local SIGMA, HALF_LIFE, PRIOR, HOLD_BAND = 0.4, 45 * 86400, 0.15, 0.6
local TICK, TOUCH_EVERY, BRIGHTER_AFTER, DARKER_AFTER = 10, 2, 2, 6
-- After a start (KOReader starting, Auto on, a wake-up) the first look waits this long: KOReader puts the light
-- back after sleep a tick or two later, and a look before that would fade against it.
local SETTLE = 1.5
-- In the dark the sensor flickers between 0 and ~0.2 lux. Below 1 lux counts as one "dark" for deciding
-- whether the room changed, and below 0.3 lux as one point on the curve (it's flat there anyway).
local LUX_FLOOR, CURVE_FLOOR = 1.0, 0.3
local function lxOf(lux) return math.log10(math.max(lux, CURVE_FLOOR)) end

-- Monotone cubic interpolation (Fritsch-Carlson) of BASE in log10 lux.
local xs, ys, ms = {}, {}, {}
do
    local n = #BASE
    for i, p in ipairs(BASE) do xs[i], ys[i] = math.log10(p[1]), p[2] end
    local d = {}
    for i = 1, n - 1 do d[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) end
    ms[1], ms[n] = d[1], d[n - 1]
    for i = 2, n - 1 do
        if d[i - 1] * d[i] <= 0 then
            ms[i] = 0
        else
            local h0, h1 = xs[i] - xs[i - 1], xs[i + 1] - xs[i]
            local w1, w2 = 2 * h1 + h0, h1 + 2 * h0
            ms[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
        end
    end
end

local function base(lx)
    if lx <= xs[1] then return ys[1] end
    if lx >= xs[#xs] then return ys[#ys] end
    for i = 1, #xs - 1 do
        if lx <= xs[i + 1] then
            local h = xs[i + 1] - xs[i]
            local t = (lx - xs[i]) / h
            local t2, t3 = t * t, t * t * t
            return (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * ms[i]
                + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * ms[i + 1]
        end
    end
end

local function powerd() return Device:getPowerDevice() end
local time = require("ui/time")
local function clock() return time.to_s(time.now()) end

-- gen: bumped whenever our pending work must stop (a hand change, Auto off, sleep); every fade step and look
-- checks it. own: true inside our own setIntensity calls and KOReader's own "light back on" (after sleep, or a
-- toggle), so a hand change is anything else.
local state = { fd = -1, samples = {}, last_sample = 0, anchor = nil, candidate = nil, hold = nil, gen = 0,
    own = false, fading = false, ticking = false, burst = false, log = {} }

local function note(...)
    local parts = { os.date("%H:%M:%S") }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    table.insert(state.log, table.concat(parts, " "))
    if #state.log > 40 then table.remove(state.log, 1) end
end

local function amazonAuto(value)
    local lipc = powerd().lipc_handle
    if not lipc then return nil end
    if value == nil then
        local ok, v = pcall(lipc.get_int_property, lipc, "com.lab126.powerd", "flAuto")
        return ok and v or nil
    end
    pcall(lipc.set_int_property, lipc, "com.lab126.powerd", "flAuto", value)
end

local function enableSensor()
    if state.fd < 0 then state.fd = ffi.C.open("/dev/als", O_RDWR) end
    if state.fd >= 0 then ffi.C.ioctl(state.fd, ALS_ENABLE, ffi.new("int[1]", 1)) end
end

local function readLux()
    local f = io.open(SENSOR)
    if not f then return nil end
    local v = tonumber(f:read("*l"))
    f:close()
    return v
end

function L.isOn() return G_reader_settings:nilOrTrue("quiet_light_auto") end

-- The level for a room light, from the curve plus what you've taught it.
function L.target(lux)
    local lx = lxOf(lux)
    local level = base(lx)
    local prefs = G_reader_settings:readSetting("quiet_light_prefs")
    if prefs and #prefs > 0 then
        local now, num, den = os.time(), 0, PRIOR
        for _, p in ipairs(prefs) do
            local w = math.exp(-((lx - p.lx) ^ 2) / (2 * SIGMA * SIGMA)) * 0.5 ^ (math.max(0, now - p.t) / HALF_LIFE)
            num = num + w * (p.level - base(p.lx))
            den = den + w
        end
        level = level + num / den
    end
    local lowest = lux >= 2000 and 0 or 1
    return math.max(lowest, math.min(math.floor(level + 0.5), powerd().fl_max))
end

local function effective(t)
    local best
    for i = #state.samples, 1, -1 do
        local s = state.samples[i]
        if t - s[1] > 4 then break end
        if not best or s[2] > best then best = s[2] end
    end
    return best
end

local function sample()
    local t = clock()
    state.last_sample = t
    local lux = readLux()
    if not lux then return nil end
    table.insert(state.samples, { t, lux })
    while #state.samples > 0 and t - state.samples[1][1] > 8 do table.remove(state.samples, 1) end
    return effective(t)
end

-- Whatever we had pending (a fade, a candidate change) stops here.
local function cancel()
    state.gen = state.gen + 1
    state.fading, state.candidate = false, nil
end

-- One level per 0.1 s. A step runs only while nothing else happened since: no newer fade, no hand change, no
-- sleep (cancel() above), and the light still where our last step left it.
local function apply(level, why)
    local p = powerd()
    local cur = p:frontlightIntensity()
    if level == cur then return end
    note("set", cur, "->", level, why)
    cancel()
    local gen = state.gen
    -- (From off, the first step's setIntensity switches the light on: KindlePowerD's setIntensityHW re-decides
    -- is_fl_on from the light itself. So it fades up from 0, never jumping to the level it had before.)
    state.fading = true
    local step = level > cur and 1 or -1
    local function nextStep()
        if gen ~= state.gen then return end
        if p:frontlightIntensity() ~= cur then
            -- moved by something other than a hand (hand changes cancel first): KOReader putting the light back
            -- after sleep. Not where we were heading, so the next look starts over.
            state.fading, state.anchor = false, nil
            return
        end
        cur = cur + step
        state.own = true
        local ok, err = pcall(p.setIntensity, p, cur)
        state.own = false
        if not ok then
            state.fading = false
            logger.warn("quiet light: step failed", err)
            return
        end
        if cur ~= level then
            UIManager:scheduleIn(0.1, nextStep)
        else
            state.fading = false
            UIManager:broadcastEvent(Event:new("QuietLightChanged"))
        end
    end
    nextStep()
end

local evaluate
local function burst()
    if state.burst then return end
    state.burst = true
    UIManager:scheduleIn(1, function()
        state.burst = false
        evaluate()
    end)
end

evaluate = function()
    if not state.ticking or not L.isOn() or state.fading then return end
    if clock() < (state.settle_until or 0) then return end
    local eff = sample()
    if not eff then return end
    local lux = math.max(eff, LUX_FLOOR)
    if state.hold then
        local r = lux / state.hold
        if r > 1 - HOLD_BAND and r < 1 + HOLD_BAND then
            state.candidate = nil
            return
        end
        note("hold released at", string.format("%.2f lux", eff))
        state.hold = nil
    end
    local want = L.target(eff)
    local cur = powerd():frontlightIntensity()
    if not state.anchor then
        state.anchor = lux
        apply(want, string.format("(start, %.2f lux)", eff))
        return
    end
    if want == cur then
        state.candidate = nil
        return
    end
    local ratio = lux / state.anchor
    if ratio < 1.25 and ratio > 0.8 then
        state.candidate = nil
        return
    end
    local dir = lux > state.anchor and 1 or -1
    local t = clock()
    if not state.candidate or state.candidate.dir ~= dir then
        state.candidate = { since = t, dir = dir }
        burst()
        return
    end
    if t - state.candidate.since >= (dir > 0 and BRIGHTER_AFTER or DARKER_AFTER) then
        state.candidate = nil
        state.anchor = lux
        apply(want, string.format("(%.2f lux)", eff))
    else
        burst()
    end
end

local function tick()
    if not state.ticking then return end
    evaluate()
    UIManager:scheduleIn(TICK, tick)
end

-- Amazon's automatic light is ours to stop while KOReader runs, whether or not our Auto is on (with it running,
-- "Auto off" would still move the light), and Amazon's status bar stays paused (its clock would paint over
-- KOReader); both come back exactly as found however KOReader ends. The whole protocol (taking over at a start,
-- giving back at a clean exit, the crash watcher, all under one lock) is patches/quiet-amazon-guard.sh, so it can
-- be tested as it runs.
local GUARD = require("datastorage"):getDataDir() .. "/patches/quiet-amazon-guard.sh"
local OWED = require("datastorage"):getSettingsDir() .. "/quiet/amazon-auto-owed"
local MY_PID = ffi.C.getpid()
-- os.execute's result here is the raw wait status (exit code * 256): 0 is the only success.
local function guard(what)
    return os.execute(string.format("sh '%s' %s %d", GUARD, what, MY_PID))
end
-- This Auto moves the light only if the takeover at this start said Amazon's auto is off (with both on, they'd fight
-- over the light). No second try in this session: it would start a second watcher and block the screen for up to
-- the guard's lock wait; the next KOReader start tries again.
local amazon_off, takeover_status = false, nil

-- What earlier versions owed Amazon (a setting) becomes the guard's file, once.
local function migrateDebt()
    if G_reader_settings:readSetting("quiet_light_amazon_auto") == 1 then
        local f = io.open(OWED, "w")
        if not f then return end
        f:close()
    end
    if G_reader_settings:has("quiet_light_amazon_auto") or G_reader_settings:has("quiet_light_amazon_restored") then
        G_reader_settings:delSetting("quiet_light_amazon_auto")
        G_reader_settings:delSetting("quiet_light_amazon_restored")
        G_reader_settings:flush()
    end
end

local function takeOverAmazon()
    migrateDebt()
    takeover_status = guard("takeover")
    amazon_off = takeover_status == 0
    if not amazon_off then
        logger.warn("quiet light: Amazon's auto light not known to be off, Auto stays idle; guard status",
            takeover_status)
        note("Amazon's auto not stopped, Auto idle (guard status " .. tostring(takeover_status) .. ")")
    end
end

-- For 8-quiet-exit.lua: everything given back (checked). False if it didn't all take; then the crash watcher
-- tries again once KOReader is gone.
function L.giveBack()
    return guard("giveback") == 0
end

local function start()
    if not amazon_off then return end
    enableSensor()
    state.anchor, state.candidate, state.samples = nil, nil, {}
    state.settle_until = clock() + SETTLE
    if not state.ticking then
        state.ticking = true
        UIManager:scheduleIn(SETTLE + 0.5, tick)
    end
end

local function stop()
    state.ticking = false
    UIManager:unschedule(tick)
    cancel()
end

function L.setOn(on)
    G_reader_settings:saveSetting("quiet_light_auto", on and true or false)
    note(on and "auto on" or "auto off")
    if on then start() else stop() end
end

-- What you set by hand while Auto is on: a preference at this light, held until the room changes.
function L.learn(level)
    local eff = sample() or 0
    local lux = math.max(eff, LUX_FLOOR)
    local lx = lxOf(eff)
    local prefs = G_reader_settings:readSetting("quiet_light_prefs") or {}
    local last = prefs[#prefs]
    if last and math.abs(last.lx - lx) < 0.15 and os.time() - last.t < 60 then
        last.level, last.t = level, os.time()
    else
        prefs[#prefs + 1] = { lx = lx, level = level, t = os.time() }
        if #prefs > 40 then table.remove(prefs, 1) end
    end
    G_reader_settings:saveSetting("quiet_light_prefs", prefs)
    state.hold, state.anchor, state.candidate = lux, lux, nil
    note("learned", level, string.format("at %.2f lux", eff))
end

-- Forget everything it learned (and any hold), then look at the room again.
function L.forget()
    G_reader_settings:saveSetting("quiet_light_prefs", {})
    cancel()
    state.hold, state.anchor = nil, nil
    note("forgot what it learned")
    if L.isOn() then UIManager:nextTick(evaluate) end
end

function L.debug()
    local lux = readLux()
    return string.format("auto=%s running=%s takeover=%s amazon_flAuto=%s lux=%s eff=%s level=%s target=%s hold=%s"
        .. " anchor=%s prefs=%d\n%s", tostring(L.isOn()), tostring(state.ticking), tostring(takeover_status),
        tostring(amazonAuto()), tostring(lux), tostring(effective(clock())),
        tostring(powerd():frontlightIntensity()), lux and tostring(L.target(lux)) or "?", tostring(state.hold),
        tostring(state.anchor), #(G_reader_settings:readSetting("quiet_light_prefs") or {}), table.concat(state.log, "\n"))
end

-- Hand changes teach it and stop any fade of ours; its own steps don't.
local p = powerd()
local setIntensity = p.setIntensity
p.setIntensity = function(self, intensity, ...)
    local r = setIntensity(self, intensity, ...)
    if not state.own then
        cancel()
        if r and L.isOn() then
            local ok, err = pcall(L.learn, intensity)
            if not ok then logger.warn("quiet light: learn failed", err) end
        end
    end
    return r
end

-- KOReader puts the light back after sleep (and on a toggle) through setIntensity: not a preference.
local turnOnFrontlightHW = p.turnOnFrontlightHW
if turnOnFrontlightHW then
    p.turnOnFrontlightHW = function(self, ...)
        local was = state.own
        state.own = true
        local ok, r = pcall(turnOnFrontlightHW, self, ...)
        state.own = was
        if not ok then error(r) end
        return r
    end
end

-- Switched off by hand (KOReader's frontlight toggle): it stays off until the room light changes as much as it
-- takes to release a hand-set level. Switched back on by hand goes through setIntensity above (learned).
local turnOffFrontlight = p.turnOffFrontlight
p.turnOffFrontlight = function(self, ...)
    if not state.own then
        cancel()
        if L.isOn() then
            local lux = math.max(sample() or 0, LUX_FLOOR)
            state.hold, state.anchor = lux, lux
            note("switched off by hand", string.format("at %.2f lux", lux))
        end
    end
    return turnOffFrontlight(self, ...)
end

-- Asleep: no readings. Awake: the sensor back on, a fresh look at the room; a long sleep forgets the hold.
local beforeSuspend, afterResume = p.beforeSuspend, p.afterResume
p.beforeSuspend = function(self, ...)
    state.slept_at = os.time()
    stop()
    return beforeSuspend(self, ...)
end
p.afterResume = function(self, ...)
    local r = afterResume(self, ...)
    if L.isOn() then
        if state.slept_at and os.time() - state.slept_at > 600 then state.hold = nil end
        start()
    end
    return r
end

-- Touches are a free moment to look (KOReader is awake anyway).
UIManager.event_hook:register("InputEvent", function()
    if L.isOn() and clock() - state.last_sample >= TOUCH_EVERY then
        UIManager:nextTick(evaluate)
    end
end)

do
    local ok, err = pcall(takeOverAmazon)
    if not ok then logger.warn("quiet light: Amazon's auto light not taken over", err) end
end
if L.isOn() then
    local ok, err = pcall(start)
    if not ok then logger.warn("quiet light: start failed", err) end
end
