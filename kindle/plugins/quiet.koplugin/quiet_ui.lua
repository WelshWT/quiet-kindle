--[[
Shared look for the Quiet reader UI: one soft shape system (same scale as patches/2-quiet-soft.lua), colours,
fonts, and the few building blocks every sheet uses.

Sizes are written in Paperwhite pixels (1272 px wide portrait) and scaled with Q.px() for other widths.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Screen = Device.screen

local Q = {}

Q.INK = Blitbuffer.COLOR_BLACK
Q.INK2 = Blitbuffer.gray(0.68)   -- secondary text
Q.LINE = Blitbuffer.gray(0.35)   -- outlines
Q.SOFT = Blitbuffer.gray(0.14)   -- selected state: a soft capsule, never a black block
Q.TRACK = Blitbuffer.gray(0.16)  -- slider and progress tracks
Q.PAPER = Blitbuffer.COLOR_WHITE

Q.R_SHEET, Q.R_DIALOG, Q.R_BUTTON = 52, 32, 24

function Q.px(v)
    return math.floor(v * math.min(Screen:getWidth(), Screen:getHeight()) / 1272 + 0.5)
end

-- Font:getFace() scales by screen size itself; ask for a size that comes out at `px` device pixels.
local function baseSize(px)
    local f = Screen:scaleBySize(1000) / 1000
    return math.max(6, math.floor(Q.px(px) / f + 0.5))
end

function Q.face(px, bold)
    return Font:getFace(bold and "Amazon-Ember-Bold.ttf" or "Amazon-Ember-Regular.ttf", baseSize(px))
end

function Q.serif(px, bold)
    return Font:getFace(bold and "Bookerly-Bold.ttf" or "Bookerly-Regular.ttf", baseSize(px))
end

-- A reading font by its family name (as the book's font menu names it), for showing a font in itself; the UI
-- font when the family can't be found.
function Q.family(name, px)
    local ok, file, index = pcall(function()
        local cre = require("document/credocument"):engineInit()
        return cre.getFontFaceFilenameAndFaceIndex(name)
    end)
    if ok and file then return Font:getFace(file, baseSize(px), index) end
    return Q.face(px)
end

Q.icon_dir = nil -- set by main.lua to <plugin>/icons/

-- The plugin's icons. main.lua sets the folder when a book opens; on Home before that (the pull-down sheet, the
-- Sleep screen sheet) it is found next to this file.
local function iconDir()
    if not Q.icon_dir then
        local src = debug.getinfo(1, "S").source or ""
        Q.icon_dir = (src:match("^@(.*/)") or "plugins/quiet.koplugin/") .. "icons/"
    end
    return Q.icon_dir
end

function Q.icon(name, size)
    return IconWidget:new{
        file = iconDir() .. name .. ".svg",
        width = Q.px(size or 56),
        height = Q.px(size or 56),
        alpha = true,
    }
end

function Q.text(str, px, opts)
    opts = opts or {}
    return TextWidget:new{
        text = str,
        face = Q.face(px, opts.bold),
        fgcolor = opts.color or Q.INK,
        max_width = opts.max_width,
    }
end

-- Row-by-row rounded rectangle with radii (tl, tr, br, bl).
local function inset(r, row)
    local yy = r - row - 0.5
    return math.floor(r - math.sqrt(math.max(0, r * r - yy * yy)) + 0.5)
end

function Q.fillRound(bb, x, y, w, h, color, tl, tr, br, bl)
    if w <= 0 or h <= 0 then return end
    local half = math.floor(math.min(w, h) / 2)
    tl, tr, br, bl = math.min(tl, half), math.min(tr, half), math.min(br, half), math.min(bl, half)
    local top, bottom = math.max(tl, tr), math.max(bl, br)
    if h - top - bottom > 0 then bb:paintRect(x, y + top, w, h - top - bottom, color) end
    for row = 0, top - 1 do
        local li = row < tl and inset(tl, row) or 0
        local ri = row < tr and inset(tr, row) or 0
        bb:paintRect(x + li, y + row, w - li - ri, 1, color)
    end
    for k = 0, bottom - 1 do
        local row = h - 1 - k
        local li = k < bl and inset(bl, k) or 0
        local ri = k < br and inset(br, k) or 0
        bb:paintRect(x + li, y + row, w - li - ri, 1, color)
    end
end

-- A rounded surface: fill plus an outline of width `bw`.
Q.Surface = Widget:extend{ w = 0, h = 0, radii = nil, fill = nil, border = nil, bw = 3 }

function Q.Surface:getSize() return Geom:new{ w = self.w, h = self.h } end

function Q.Surface:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local r = self.radii or { 0, 0, 0, 0 }
    local fill = self.fill or Q.PAPER
    if self.border and self.bw > 0 then
        local b = self.bw
        Q.fillRound(bb, x, y, self.w, self.h, self.border, r[1], r[2], r[3], r[4])
        Q.fillRound(bb, x + b, y + b, self.w - 2 * b, self.h - 2 * b, fill,
            math.max(0, r[1] - b), math.max(0, r[2] - b), math.max(0, r[3] - b), math.max(0, r[4] - b))
    else
        Q.fillRound(bb, x, y, self.w, self.h, fill, r[1], r[2], r[3], r[4])
    end
end

-- A panel: a Surface with content painted on top at (pad_x, pad_y). Content can be any widget.
Q.Panel = Widget:extend{ w = 0, h = 0, radii = nil, border = nil, bw = 3, pad_x = 0, pad_y = 0, content = nil, fill = nil }

function Q.Panel:init()
    self.bg = Q.Surface:new{ w = self.w, h = self.h, radii = self.radii, border = self.border, bw = self.bw, fill = self.fill }
    self.dimen = Geom:new{ w = self.w, h = self.h }
end

function Q.Panel:getSize() return Geom:new{ w = self.w, h = self.h } end

function Q.Panel:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    self.bg:paintTo(bb, x, y)
    if self.content then self.content:paintTo(bb, x + self.pad_x, y + self.pad_y) end
end

function Q.Panel:handleEvent(ev)
    return self.content and self.content:handleEvent(ev)
end

-- A tappable area of fixed size, with an optional soft capsule behind its content when `selected`.
Q.Tap = InputContainer:extend{
    w = 0, h = 0, content = nil, callback = nil, hold_callback = nil, selected = false,
    capsule_radius = nil, -- nil = pill
}

function Q.Tap:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self[1] = CenterContainer:new{ dimen = Geom:new{ w = self.w, h = self.h }, self.content }
    self.ges_events = {
        TapQuiet = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldQuiet = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function Q.Tap:getSize() return Geom:new{ w = self.w, h = self.h } end

function Q.Tap:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self.selected then
        local r = self.capsule_radius or math.floor(self.h / 2)
        Q.fillRound(bb, x, y, self.w, self.h, Q.SOFT, r, r, r, r)
    end
    self[1]:paintTo(bb, x, y)
end

function Q.Tap:onTapQuiet()
    if self.callback then self.callback() end
    return true
end

function Q.Tap:onHoldQuiet()
    if self.hold_callback then
        self.hold_callback()
        return true
    end
    return self.callback ~= nil
end

-- Icon with a word under it (toolbar, toggles, selection bar).
function Q.iconLabel(icon_name, label, opts)
    opts = opts or {}
    local vg = VerticalGroup:new{ align = "center" }
    if icon_name == "Aa" then
        local size = opts.icon or 56
        vg[#vg + 1] = CenterContainer:new{ dimen = Geom:new{ w = Q.px(size), h = Q.px(size) },
            Q.text("Aa", opts.icon_text_px or 44, { bold = false }) }
    else
        vg[#vg + 1] = Q.icon(icon_name, opts.icon or 56)
    end
    if label then
        vg[#vg + 1] = VerticalSpan:new{ width = Q.px(6) }
        vg[#vg + 1] = Q.text(label, opts.label_px or 25, { bold = opts.bold, color = opts.label_color })
    end
    return vg
end

function Q.hspan(px) return HorizontalSpan:new{ width = Q.px(px) } end
function Q.vspan(px) return VerticalSpan:new{ width = Q.px(px) } end

function Q.row(...)
    return HorizontalGroup:new{ align = "center", ... }
end

-- A small round dot: filled when on, a ring when off (the Auto chip).
Q.Dot = Widget:extend{ size = 16, on = false }
function Q.Dot:getSize() return Geom:new{ w = Q.px(self.size), h = Q.px(self.size) } end
function Q.Dot:paintTo(bb, x, y)
    local d = Q.px(self.size)
    local r = math.floor(d / 2)
    Q.fillRound(bb, x, y, d, d, self.on and Q.INK or Q.INK2, r, r, r, r)
    if not self.on then
        local b = Q.px(3)
        Q.fillRound(bb, x + b, y + b, d - 2 * b, d - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)
    end
end

-- Pill-shaped track with a fill and a round knob (brightness, warmth, scrubber).
Q.Track = InputContainer:extend{ w = 0, h = 0, value = 0, track_h = 10, knob = 52, on_set = nil }

function Q.Track:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = { TapTrack = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function Q.Track:getSize() return Geom:new{ w = self.w, h = self.h } end

function Q.Track:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local th = Q.px(self.track_h)
    local ty = y + math.floor((self.h - th) / 2)
    local r = math.floor(th / 2)
    local pad = math.floor(Q.px(self.knob) / 2)
    local tw = self.w - 2 * pad
    Q.fillRound(bb, x + pad, ty, tw, th, Q.TRACK, r, r, r, r)
    local v = math.max(0, math.min(self.value or 0, 1))
    local fw = math.floor(tw * v)
    if fw > 0 then Q.fillRound(bb, x + pad, ty, math.max(fw, th), th, Q.INK2, r, r, r, r) end
    local k = Q.px(self.knob)
    local kx = x + pad + fw - math.floor(k / 2)
    local ky = y + math.floor((self.h - k) / 2)
    local kr = math.floor(k / 2)
    Q.fillRound(bb, kx, ky, k, k, Q.INK, kr, kr, kr, kr)
    local b = Q.px(6)
    Q.fillRound(bb, kx + b, ky + b, k - 2 * b, k - 2 * b, Q.PAPER, kr - b, kr - b, kr - b, kr - b)
end

function Q.Track:onTapTrack(_, ges)
    local pad = math.floor(Q.px(self.knob) / 2)
    local v = (ges.pos.x - self.dimen.x - pad) / (self.w - 2 * pad)
    v = math.max(0, math.min(v, 1))
    self.value = v
    if self.on_set then self.on_set(v) end
    return true
end

return Q
