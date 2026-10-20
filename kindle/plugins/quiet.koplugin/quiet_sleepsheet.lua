--[[
Sleep screen sheet (asked for: "I like all 5, just let the user choose between em"): opened from the Sleep screen row of
the pull-down sheet, on Home, Library, Stats and in a book.
  - QUIET: the five covers in a row, with their own Shuffle and Light / Dark above them on the right. Both only apply
    to the QUIET covers ("shuffle ... only when u have one of the text ones selected"), so they are greyed out while
    Book cover or Frosted is chosen. With Shuffle on, all five are outlined: all five take turns.
  - Below a hairline: Book cover and Frosted.
The chosen tile is outlined in the selected style with its name in bold; a tap chooses, and the next sleep shows it.
Thumbnails are small files made with the covers (data/quiet-sleep/tiles/), scaled once and kept for the session;
Book cover shows the current book's cover from CoverBrowser's cache.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local Q = require("quiet_ui")
local Sheet = require("quiet_sheet")
local Sleep = require("quiet_sleep")

local SleepSheet = Sheet:extend{ anchor = "bottom" }

-- Thumbnails --------------------------------------------------------------------------------------------------------

local thumbs = {} -- scaled once, kept for the session (about 60 KB each)

local function grey(bb)
    if bb:getType() == Blitbuffer.TYPE_BB8 then return bb end
    local g = Blitbuffer.new(bb:getWidth(), bb:getHeight(), Blitbuffer.TYPE_BB8)
    g:blitFrom(bb, 0, 0, 0, 0, bb:getWidth(), bb:getHeight())
    bb:free()
    return g
end

local function fileThumb(name, w, h)
    local key = name .. ":" .. w .. "x" .. h
    if thumbs[key] == nil then
        thumbs[key] = false
        local RenderImage = require("ui/renderimage")
        local bb = RenderImage:renderImageFile(Sleep.dataDir() .. "tiles/" .. name .. ".png", false)
        if bb then
            thumbs[key] = grey(RenderImage:scaleBlitBuffer(bb, w, h, true))
        else
            logger.warn("quiet sleep sheet: no tile", name)
        end
    end
    return thumbs[key] or nil
end

-- The current book's cover on a white tile, laid out as the Book cover sleep screen does.
local cover_thumb = { key = nil, bb = nil }

local function coverThumb(ui, w, h)
    local file = ui and ui.document and ui.document.file or G_reader_settings:readSetting("lastfile")
    if not file then return nil end
    local key = file .. ":" .. w .. "x" .. h
    if cover_thumb.key == key then return cover_thumb.bb end
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    local info = ok and BookInfoManager:getBookInfo(file, true)
    local src = info and info.cover_bb
    if not src then return nil end
    local tile = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    tile:fill(Blitbuffer.COLOR_WHITE)
    local mw, mh = w - Q.px(44), h - Q.px(70)
    local s = math.min(mw / src:getWidth(), mh / src:getHeight())
    local RenderImage = require("ui/renderimage")
    local art = grey(RenderImage:scaleBlitBuffer(src, src:getWidth() * s, src:getHeight() * s, true))
    local aw, ah = art:getWidth(), art:getHeight()
    local x, y = math.floor((w - aw) / 2), Q.px(22) + math.floor((mh - ah) / 2)
    Q.fillRound(tile, x - 1, y - 1, aw + 2, ah + 2, Blitbuffer.gray(0.30), Q.px(6), Q.px(6), Q.px(6), Q.px(6))
    tile:blitFrom(art, x, y, 0, 0, aw, ah)
    art:free()
    Q.fillRound(tile, x, y + ah + Q.px(14), aw, Q.px(3), Q.TRACK, 1, 1, 1, 1)
    if cover_thumb.bb then cover_thumb.bb:free() end
    cover_thumb.key, cover_thumb.bb = key, tile
    return tile
end

local function noBook(bb, x, y, w, h)
    local t = TextWidget:new{ text = "No book yet", face = Q.face(23), fgcolor = Q.INK2 }
    local ts = t:getSize()
    t:paintTo(bb, x + math.floor((w - ts.w) / 2), y + math.floor((h - ts.h) / 2))
    t:free()
end

-- Pieces ------------------------------------------------------------------------------------------------------------

-- A tile: the picture in a rounded outline (the selected style when `on`) and its name under it.
local Tile = Widget:extend{ w = 0, h = 0, pic_h = 0, label = "", on = false, bold = false, thumb = nil, draw = nil }

function Tile:getSize() return Geom:new{ w = self.w, h = self.h } end

function Tile:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local r, frame = Q.px(16), Q.px(5)
    local b = self.on and frame or Q.px(3)
    Q.fillRound(bb, x, y, self.w, self.pic_h, self.on and Q.INK2 or Q.LINE, r, r, r, r)
    Q.fillRound(bb, x + b, y + b, self.w - 2 * b, self.pic_h - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)
    -- the picture sits inside the thicker frame either way, so choosing a tile doesn't move it
    local ix, iy = x + frame + 1, y + frame + 1
    local iw, ih = self.w - 2 * frame - 2, self.pic_h - 2 * frame - 2
    if self.thumb then
        bb:blitFrom(self.thumb, ix, iy, 0, 0, math.min(iw, self.thumb:getWidth()), math.min(ih, self.thumb:getHeight()))
        local rr = r - frame
        for dy = 0, rr - 1 do
            local yy = rr - dy - 0.5
            local inset = math.floor(rr - math.sqrt(rr * rr - yy * yy) + 0.5)
            if inset > 0 then
                bb:paintRect(ix, iy + dy, inset, 1, Q.PAPER)
                bb:paintRect(ix + iw - inset, iy + dy, inset, 1, Q.PAPER)
                bb:paintRect(ix, iy + ih - 1 - dy, inset, 1, Q.PAPER)
                bb:paintRect(ix + iw - inset, iy + ih - 1 - dy, inset, 1, Q.PAPER)
            end
        end
    elseif self.draw then
        self.draw(bb, ix, iy, iw, ih)
    end
    local t = TextWidget:new{ text = self.label, face = Q.face(26, self.bold), fgcolor = Q.INK, max_width = self.w }
    local ts = t:getSize()
    t:paintTo(bb, x + math.floor((self.w - ts.w) / 2), y + self.pic_h + math.floor((self.h - self.pic_h - ts.h) / 2))
    t:free()
end

-- Shuffle: a pill like the Library's Hide read: a check mark and the soft fill when on, grey when it can't apply.
local ShuffleChip = InputContainer:extend{ h = 0, on = false, enabled = true, on_tap = nil }

function ShuffleChip:init()
    local px = Q.px
    -- as wide as it is when on, so turning it on doesn't move it; text and icon are made at paint and freed
    self.isz = px(36) -- the check mark: 36 design px (Q.icon scales it the same way)
    local probe = Q.text("Shuffle", 27, { bold = true })
    self.pad, self.gap = px(18), px(10)
    self.w = self.pad + self.isz + self.gap + probe:getSize().w + self.pad
    probe:free()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        TapShuffle = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function ShuffleChip:getSize() return Geom:new{ w = self.w, h = self.h } end

function ShuffleChip:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h, b = self.w, self.h, Q.px(3)
    local r = math.floor(h / 2)
    local lit = self.on and self.enabled
    Q.fillRound(bb, x, y, w, h, lit and Q.INK2 or Q.LINE, r, r, r, r)
    Q.fillRound(bb, x + b, y + b, w - 2 * b, h - 2 * b, lit and Q.SOFT or Q.PAPER, r - b, r - b, r - b, r - b)
    local label = Q.text("Shuffle", 27, { color = self.enabled and Q.INK or Q.INK2, bold = lit })
    local lsz = label:getSize()
    local lx = x + math.floor((w - lsz.w) / 2)
    if lit then
        local icon = Q.icon("check", 36)
        local isz = icon:getSize()
        lx = x + math.floor((w - isz.w - self.gap - lsz.w) / 2)
        icon:paintTo(bb, lx, y + math.floor((h - isz.h) / 2))
        if icon.free then icon:free() end
        lx = lx + isz.w + self.gap
    end
    label:paintTo(bb, lx, y + math.floor((h - lsz.h) / 2))
    label:free()
end

function ShuffleChip:onTapShuffle()
    if self.enabled and self.on_tap then self.on_tap() end
    return true
end

-- Light / Dark: a two-part pill like the Library's grid/list switch; greyed when it can't apply.
local LightDark = InputContainer:extend{ h = 0, w = 0, dark = false, enabled = true, on_change = nil }

function LightDark:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        TapLightDark = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function LightDark:getSize() return Geom:new{ w = self.w, h = self.h } end

function LightDark:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h, b, inset = self.w, self.h, Q.px(3), Q.px(5)
    local r = math.floor(h / 2)
    Q.fillRound(bb, x, y, w, h, Q.LINE, r, r, r, r)
    Q.fillRound(bb, x + b, y + b, w - 2 * b, h - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)
    local seg = math.floor((w - 2 * (b + inset)) / 2)
    local sh = h - 2 * (b + inset)
    local sr = math.floor(sh / 2)
    for i, name in ipairs({ "Light", "Dark" }) do
        local sx, sy = x + b + inset + (i - 1) * seg, y + b + inset
        local on = ((i == 2) == self.dark) and self.enabled
        if on then Q.fillRound(bb, sx, sy, seg, sh, Q.SOFT, sr, sr, sr, sr) end
        local t = TextWidget:new{ text = name, face = Q.face(27, on), fgcolor = self.enabled and Q.INK or Q.INK2 }
        local ts = t:getSize()
        t:paintTo(bb, sx + math.floor((seg - ts.w) / 2), sy + math.floor((sh - ts.h) / 2))
        t:free()
    end
end

function LightDark:onTapLightDark(_, ges)
    if not self.enabled then return true end
    local want = (ges.pos.x - self.dimen.x) >= self.w / 2
    if want ~= self.dark and self.on_change then self.on_change(want) end
    return true
end

-- A thin rule across the sheet, between the QUIET covers and the other two.
local Rule = Widget:extend{ w = 0 }
function Rule:getSize() return Geom:new{ w = self.w, h = Q.px(2) } end
function Rule:paintTo(bb, x, y) bb:paintRect(x, y, self.w, Q.px(2), Q.LINE) end

-- The sheet ---------------------------------------------------------------------------------------------------------

function SleepSheet:build()
    local W, px = self.W, Q.px
    local inner = W - 2 * px(56)
    local mode, shuffle, dark = Sleep.mode(), Sleep.shuffle(), Sleep.dark()
    local quiet_on = Sleep.isQuiet(mode)

    local title = LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(64) },
        Q.text("Sleep screen", 35, { bold = true }) }

    -- QUIET: its label on the left, its Shuffle and Light / Dark on the right
    local chip = ShuffleChip:new{ h = px(64), on = shuffle, enabled = quiet_on, on_tap = function()
        Sleep.setShuffle(not Sleep.shuffle())
        self:refresh()
    end }
    local switch = LightDark:new{ w = px(260), h = px(64), dark = dark, enabled = quiet_on, on_change = function(v)
        Sleep.setDark(v)
        self:refresh()
    end }
    local controls = HorizontalGroup:new{ align = "center", chip, Q.hspan(16), switch }
    local quiet_head = OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = px(70) },
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(70) },
            Q.text("QUIET covers", 27, { color = quiet_on and Q.INK or Q.INK2 }) },
        RightContainer:new{ dimen = Geom:new{ w = inner, h = px(70) }, controls },
    }

    local gap = px(20)
    local tw = math.floor((inner - 4 * gap) / 5)
    local pic_h = math.floor(tw * 1696 / 1272)
    local th = pic_h + px(54)
    local iw, ih = tw - 2 * px(5) - 2, pic_h - 2 * px(5) - 2

    local function tap(tile, cb)
        return Q.Tap:new{ w = tw, h = th, content = tile, callback = cb, hold_callback = cb }
    end

    local quiet_row = HorizontalGroup:new{ align = "top" }
    for i = 1, 5 do
        local id = "quiet-" .. i
        local chosen = quiet_on and (shuffle or mode == id)
        local tile = Tile:new{ w = tw, h = th, pic_h = pic_h, label = Sleep.name(id),
            on = chosen, bold = quiet_on and not shuffle and mode == id,
            thumb = fileThumb(id .. (dark and "-dark" or ""), iw, ih) }
        if i > 1 then quiet_row[#quiet_row + 1] = Q.hspan(20) end
        quiet_row[#quiet_row + 1] = tap(tile, function()
            -- a cover of your own choosing: Shuffle stops
            if mode == id and not shuffle then return end
            Sleep.setMode(id)
            Sleep.setShuffle(false)
            self:refresh()
        end)
    end

    local other_row = HorizontalGroup:new{ align = "top" }
    for i, id in ipairs({ "cover", "frosted" }) do
        local thumb, draw
        if id == "cover" then
            local ok, res = pcall(coverThumb, self.ui, iw, ih)
            thumb = ok and res or nil
            if not thumb then draw = noBook end
        else
            thumb = fileThumb("frosted", iw, ih)
        end
        local tile = Tile:new{ w = tw, h = th, pic_h = pic_h, label = Sleep.name(id),
            on = mode == id, bold = mode == id, thumb = thumb, draw = draw }
        if i > 1 then other_row[#other_row + 1] = Q.hspan(20) end
        other_row[#other_row + 1] = tap(tile, function()
            if mode == id then return end
            Sleep.setMode(id)
            self:refresh()
        end)
    end

    self.content = VerticalGroup:new{
        align = "center",
        Q.vspan(22), Sheet.grip(), Q.vspan(14),
        title, Q.vspan(10),
        quiet_head, Q.vspan(14),
        quiet_row, Q.vspan(18),
        Rule:new{ w = inner }, Q.vspan(22),
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = th }, other_row },
        Q.vspan(26),
    }
    self.panel_h = self.content:getSize().h + px(6)
    self.content = CenterContainer:new{ dimen = Geom:new{ w = W, h = self.panel_h }, self.content }
end

-- Open from the pull-down sheet's host: the reader's Quiet plugin, or Home's small host.
function SleepSheet.open(host, ui)
    if host.showSheet then
        host:showSheet("quiet_sleepsheet")
        return
    end
    local ok, s = pcall(function() return SleepSheet:new{ plugin = host, ui = ui } end)
    if not ok then
        logger.warn("quiet sleep sheet failed:", s)
        return
    end
    host.sheet = s
    UIManager:show(s, "ui")
end

return SleepSheet
