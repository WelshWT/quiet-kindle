-- Latency tracer for KOReader on the Kindle (installed by bin/ktrace, gone after a restart).
-- Records, with millisecond timestamps: every gesture, every repaint that took time, and every e-ink update
-- with the framebuffer driver's own notes (waveform, region, waits for earlier updates).
local time = require("ui/time")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
QTRACE = {}
local function rec(...)
    if #QTRACE > 600 then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    QTRACE[#QTRACE + 1] = { time.now(), table.concat(parts, " ") }
end
QTRACE_MARK = rec
if not QTRACE_INSTALLED then
    QTRACE_INSTALLED = true
    local default = UIManager.event_handlers.__default__
    UIManager.event_handlers.__default__ = function(ev)
        if ev and ev.handler == "onGesture" and ev.args and ev.args[1] then
            local g = ev.args[1]
            rec("gesture", g.ges, g.pos and (g.pos.x .. "," .. g.pos.y) or "")
        end
        return default(ev)
    end
    local repaint = UIManager._repaint
    UIManager._repaint = function(self)
        local t = time.now()
        repaint(self)
        local ms = time.to_ms(time.since(t))
        if ms >= 1 then rec("repaint", string.format("%.0fms", ms)) end
    end
    Screen.debug = function(...) rec("fb", ...) end
    local refresh = Screen.mech_refresh
    Screen.mech_refresh = function(fb, is_flashing, wfm, x, y, w, h, dither)
        local t = time.now()
        refresh(fb, is_flashing, wfm, x, y, w, h, dither)
        rec("update", is_flashing and "flash" or "", "wfm", wfm, x, y, w, h,
            string.format("returned after %.0fms", time.to_ms(time.since(t))))
    end
end
function QTRACE_DUMP()
    local t0 = QTRACE[1] and QTRACE[1][1]
    local out = {}
    for _, r in ipairs(QTRACE) do
        out[#out + 1] = string.format("%6.0f %s", time.to_ms(r[1] - t0), r[2])
    end
    QTRACE = {}
    return #out > 0 and table.concat(out, "\n") or "(nothing since the last dump)"
end
return "tracing"
