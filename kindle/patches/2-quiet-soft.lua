--[[
Quiet soft shapes for SimpleUI (home screen), applied at runtime so SimpleUI's own files stay untouched:
  - the "framed" bottom bar becomes a full pill (radius = half its height) with a softer outline
  - the bar has no frame (change 030) and no line above it; the active tab shows a soft pill behind its filled icon, and bold
  - progress bars get rounded ends
Research behind it: people prefer curved over sharp contours (Bar & Neta 2006; meta-analysis Chuquichambi
et al. 2022, g = 0.39); see "Shapes" in docs/design.md.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local userpatch = require("userpatch")

local CAPSULE = Blitbuffer.gray(0.12)  -- active tab
local OUTLINE = Blitbuffer.gray(0.35)  -- pill bar outline
local TRACK = Blitbuffer.gray(0.15)    -- progress track
local FILL = Blitbuffer.gray(0.75)     -- progress fill

-- Filled rounded rectangle, drawn row by row (KOReader's anti-aliased corner routine only strokes outlines
-- when the border width equals the radius).
local function roundRect(bb, x, y, w, h, color, r)
    r = math.min(r, math.floor(h / 2), math.floor(w / 2))
    if r <= 0 then
        bb:paintRect(x, y, w, h, color)
        return
    end
    bb:paintRect(x + r, y, w - 2 * r, h, color)
    bb:paintRect(x, y + r, r, h - 2 * r, color)
    bb:paintRect(x + w - r, y + r, r, h - 2 * r, color)
    for dy = 0, r - 1 do
        local yy = r - dy - 0.5
        local inset = math.floor(r - math.sqrt(r * r - yy * yy) + 0.5)
        local span = r - inset
        if span > 0 then
            bb:paintRect(x + inset, y + dy, span, 1, color)
            bb:paintRect(x + w - r, y + dy, span, 1, color)
            bb:paintRect(x + inset, y + h - 1 - dy, span, 1, color)
            bb:paintRect(x + w - r, y + h - 1 - dy, span, 1, color)
        end
    end
end

local Capsule = Widget:extend{ w = 0, h = 0, color = CAPSULE }
function Capsule:getSize() return Geom:new{ w = self.w, h = self.h } end
function Capsule:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    roundRect(bb, x, y, self.w, self.h, self.color, math.floor(self.h / 2))
end

local RoundBar = Widget:extend{ w = 0, h = 0, pct = 0, fg = FILL, bg = TRACK } -- fg/bg: SimpleUI's colours if given
function RoundBar:getSize() return Geom:new{ w = self.w, h = self.h } end
function RoundBar:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local r = math.floor(self.h / 2)
    roundRect(bb, x, y, self.w, self.h, self.bg, r)
    local fw = math.floor(self.w * math.max(0, math.min(self.pct or 0, 1)))
    if fw > 0 then roundRect(bb, x, y, math.max(fw, self.h), self.h, self.fg, r) end
end

-- One shape scale for everything (device pixels, 300 ppi; Material 3 shape scale converted):
-- covers ~1.2 mm, buttons 24, dialogs and cards 32, sheets 52 (drawn by the Quiet plugin), pills = half height.
local Size = require("ui/size")
Size.radius.window = 32
Size.radius.button = 24

-- Book covers everywhere (home, collections, library, page thumbnails) are an image inside a thin square
-- frame. Round that frame, soften its colour, and mask the image's corners so they follow the curve.
local FrameContainer = require("ui/widget/container/framecontainer")
local ImageWidget = require("ui/widget/imagewidget")
local COVER_EDGE = Blitbuffer.gray(0.30)
local PAPER = Blitbuffer.COLOR_WHITE

local function maskCorners(bb, x, y, w, h, r, color)
    r = math.min(r, math.floor(h / 2), math.floor(w / 2))
    for dy = 0, r - 1 do
        local yy = r - dy - 0.5
        local inset = math.floor(r - math.sqrt(r * r - yy * yy) + 0.5)
        if inset > 0 then
            bb:paintRect(x, y + dy, inset, 1, color)
            bb:paintRect(x + w - inset, y + dy, inset, 1, color)
            bb:paintRect(x, y + h - 1 - dy, inset, 1, color)
            bb:paintRect(x + w - inset, y + h - 1 - dy, inset, 1, color)
        end
    end
end

local function coverRadius(w, h)
    return math.max(8, math.min(18, math.floor(math.min(w, h) * 0.06 + 0.5)))
end

local orig_frame_paint = FrameContainer.paintTo
function FrameContainer:paintTo(bb, x, y)
    local child = self[1]
    local is_cover = self._quiet_cover
    if is_cover == nil then
        is_cover = false
        if child and getmetatable(child) and child.image and not self.background
                and (self.bordersize or 0) > 0 and (self.bordersize or 0) <= 3 and not self.radius then
            local ok, sz = pcall(child.getSize, child)
            if ok and sz and sz.w >= 60 and sz.h >= 80 then
                local is_image = false
                local mt = getmetatable(child)
                while mt do
                    if mt == ImageWidget or mt.__index == ImageWidget then is_image = true break end
                    mt = getmetatable(mt.__index or {})
                end
                is_cover = is_image or child.is_cover == true
            end
        end
        self._quiet_cover = is_cover
        if is_cover then
            local sz = child:getSize()
            self._quiet_r = coverRadius(sz.w, sz.h)
            self.radius = self._quiet_r
            self.color = COVER_EDGE
        end
    end
    orig_frame_paint(self, bb, x, y)
    if is_cover then
        local b = self.bordersize + (self.margin or 0)
        local sz = child:getSize()
        maskCorners(bb, x + b, y + b, sz.w, sz.h, math.max(2, self._quiet_r - self.bordersize), PAPER)
        -- the border's anti-aliased curve sits on top of the masked corner
        bb:paintBorder(x + (self.margin or 0), y + (self.margin or 0), sz.w + 2 * self.bordersize,
            sz.h + 2 * self.bordersize, self.bordersize, self.color, self._quiet_r, 1)
    end
end

-- KOReader's own progress bars (library grid, dialogs) as pills. They keep what the stock bar means: the fill
-- grows from the side KOReader would grow it from (mirrored UI, inverted for the book's reading direction, or
-- fill_from_right); bars with chapter ticks, a start marker or non-linear sections (alt) keep the original drawing.
local BD = require("ui/bidi")
local ProgressWidget = require("ui/widget/progresswidget")
local orig_progress_paint = ProgressWidget.paintTo
function ProgressWidget:paintTo(bb, x, y)
    if (self.ticks and #self.ticks > 0) or self.initial_percentage or (self.alt and self.alt[1] ~= nil) then
        return orig_progress_paint(self, bb, x, y)
    end
    local sz = self:getSize()
    if not self.dimen then
        self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    else
        self.dimen.x, self.dimen.y = x, y
    end
    local r = math.floor(sz.h / 2)
    roundRect(bb, x, y, sz.w, sz.h, TRACK, r)
    local pct = math.max(0, math.min(self.percentage or 0, 1))
    if pct > 0 then
        local fw = math.max(math.floor(sz.w * pct), sz.h)
        local mirrored = BD.mirroredUILayout()
        if self.invert_direction then mirrored = not mirrored end
        local fx = (self.fill_from_right or mirrored) and (x + sz.w - fw) or x
        roundRect(bb, fx, y, fw, sz.h, self.fillcolor or FILL, r)
    end
end

-- CoverBrowser marks every book that's in a collection with a star in a grey square; with four collections
-- that's almost every cover. It already skips the mark inside collection views, so draw every grid as one.
-- Same wrapper drops the folded-corner "opened" triangle.
local mosaic_patched = false
userpatch.registerPatchPluginFunc("coverbrowser", function()
    if mosaic_patched then return end
    local ok, MosaicMenu = pcall(require, "mosaicmenu")
    if not ok or not MosaicMenu._updateItemsBuildUI then return end
    local Item = userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
    if not Item or not Item.paintTo then return end
    mosaic_patched = true
    local orig_item_paint = Item.paintTo
    Item.paintTo = function(self, bb, x, y)
        local menu = self.menu
        if not menu then return orig_item_paint(self, bb, x, y) end
        local name = menu.name
        menu.name = "collections"
        self.do_hint_opened = false -- the folded-corner "opened" mark is another sharp triangle
        local ok2, err = pcall(orig_item_paint, self, bb, x, y)
        menu.name = name
        if not ok2 then error(err) end
    end
end)

local patched = false
userpatch.registerPatchPluginFunc("simpleui", function()
    if patched then return end
    patched = true

    local okB, Bottom = pcall(require, "screens/sui_bottombar")
    -- No line above the bar (asked 20 Oct: "do we even really need the hairline?"): Quiet's screens are paged, so
    -- nothing runs under the bar, and the white space above it (twice the spacing inside the tab row or more: ~59 px on
    -- the Library, ~131 px on Home) and the active pill already set it apart (Gestalt proximity; Material 3's bar has
    -- no divider). With no separator SimpleUI's plain style puts a space of TOP_SP there instead.
    if okB and type(Bottom) == "table" then Bottom.SEP_H = function() return 0 end end
    -- Room around the hairline (asked 20 Oct: the line "uncomfortably close ... a much bigger margin below the menu
    -- buttons than there is above"; measured on the Library: the page row 1.5 mm above the line, the pill 0.7 mm under
    -- it, 4.5 mm under the labels). Material 3's bar has 12 dp above its pill and 16 dp under the label. Now ~3 mm
    -- above where the line was, ~2 mm from there to the pill and ~2 mm under the labels, with SimpleUI's spaces:
    -- TOP_SP above (where the line was), BOT_SP the margin under the bar, and `below` on top of the tab row.
    local below = 0
    if okB and type(Bottom) == "table" and Bottom.TOP_SP and Bottom.BOT_SP and Bottom.TOTAL_H then
        local Screen = require("device").screen
        below = Screen:scaleBySize(6)
        Bottom.TOP_SP = function() return Screen:scaleBySize(10) end
        Bottom.BOT_SP = function() return Screen:scaleBySize(3) end
        local total = Bottom.TOTAL_H
        Bottom.TOTAL_H = function()
            local h = total()
            return (h > 0 and Bottom.getBarStyle and Bottom.getBarStyle() == "default") and h + below or h
        end
    end
    if okB and Bottom.buildBarWidget then
        local build, idx = userpatch.getUpValue(Bottom.buildBarWidget, "_buildBarContainer")
        if build then
            userpatch.replaceUpValue(Bottom.buildBarWidget, idx, function(hg_args, is_navpager)
                local wrapper = build(hg_args, is_navpager)
                local inner = wrapper and wrapper[1]
                if inner and inner.radius and inner.getSize then
                    inner.radius = math.floor(inner:getSize().h / 2)
                    inner.color = OUTLINE
                end
                -- the plain style is [space + hairline, tab row]: the space under the line goes on top of the tab row
                local row = wrapper and wrapper[2]
                if below > 0 and Bottom.getBarStyle() == "default" and row and row.padding_bottom ~= nil then
                    row.padding_top = below
                    if wrapper.resetLayout then wrapper:resetLayout() end
                end
                return wrapper
            end)
        else
            logger.warn("quiet soft: bar builder not found")
        end
    end

    -- The active tab (asked 20 Oct: the bar's pill outline "completely unnecessary", the selection could fit the
    -- theme better): Material 3's navigation bar pattern. A soft pill behind the icon only, the icon's filled twin
    -- (<name>-fill.svg next to it) and SimpleUI's bold label, so the state never rests on a faint grey alone (WCAG
    -- 1.4.1); the other tabs stay outlined. Pill 2.4 x 1.2 icon boxes (M3: 64 x 32 dp around a 24 dp icon), the
    -- labels of every tab just under it (M3: 4 dp; the label's glyphs sit ~14 px below the pill).
    local okR, Render = pcall(require, "engines/sui_quickactions_render")
    local okQ, QA = pcall(require, "features/sui_quickactions")
    if okR and Render.buildTabCell then
        local lfs = require("libs/libkoreader-lfs")
        local orig = Render.buildTabCell
        Render.buildTabCell = function(action_id, active, spec)
            local getEntry = active and okQ and type(QA) == "table" and QA.getEntry
            if getEntry then
                QA.getEntry = function(id)
                    local e = getEntry(id)
                    if id == action_id and type(e) == "table" and type(e.icon) == "string" then
                        local filled = e.icon:gsub("%.svg$", "-fill.svg")
                        if filled ~= e.icon and lfs.attributes(filled, "mode") == "file" then
                            local copy = {}
                            for k, v in pairs(e) do copy[k] = v end
                            copy.icon = filled
                            return copy
                        end
                    end
                    return e
                end
            end
            local ok, og = pcall(orig, action_id, active, spec)
            if getEntry then QA.getEntry = getEntry end
            if not ok then error(og, 0) end
            local vg = og and og[1] and og[1][1]
            local span = vg and vg[2]
            if spec and spec.icon_sz and span and span.width and vg[3] then
                -- every tab's label clears the pill's lower edge
                span.width = span.width + math.floor(spec.icon_sz * 0.1) + 1
                if vg.resetLayout then vg:resetLayout() end
            end
            if active and og and spec and spec.tab_w and spec.bar_h and spec.icon_sz then
                -- no line along the top of the cell (SimpleUI's default style marks the active tab with one)
                for i = #og, 2, -1 do
                    local w = og[i]
                    if w.background and w.dimen and w.dimen.h == spec.indic_h then table.remove(og, i) end
                end
                local vg_h = vg and vg.getSize and vg:getSize().h or spec.icon_sz
                local icon_top = math.floor((spec.bar_h - vg_h) / 2)
                local cap_h, cap_w = math.floor(spec.icon_sz * 1.2), math.floor(spec.icon_sz * 2.4)
                local cap = Capsule:new{ w = cap_w, h = cap_h }
                cap.overlap_offset = { math.floor((spec.tab_w - cap_w) / 2),
                    icon_top + math.floor((spec.icon_sz - cap_h) / 2) }
                table.insert(og, 1, cap)
            end
            return og
        end
    end

    local okC, Core = pcall(require, "infra/sui_core")
    if okC and Core.progressBar then
        local orig = Core.progressBar
        Core.progressBar = function(w, pct, bar_h, fg_color, bg_color)
            local ok, SUISettings = pcall(require, "infra/sui_store")
            if ok and SUISettings:get("simpleui_style_progress_bar_type") == "framed" then
                return orig(w, pct, bar_h, fg_color, bg_color)
            end
            local Screen = require("device").screen
            return RoundBar:new{ w = w, h = bar_h or Screen:scaleBySize(4), pct = pct or 0,
                fg = fg_color or FILL, bg = bg_color or TRACK }
        end
    end
end)
