--[[
Text sheet (Aa), Kindle's Aa menu in two tabs (asked 20 Oct: "as many as there are in the native Kindle reader,
like being able to mess with margins and font ... just not the really nitty-gritty ones"):
  - Text: text size in 8 steps, the four looks, the font (the Kindle's reading fonts this Kindle has).
  - Layout: margins, line spacing and alignment, three or two steps each, drawn as little pages like Amazon's.
A look is a one-tap preset; a margin, spacing or alignment picked by hand makes it "Custom". Everything here is one
set for every book (main.lua). The page stays visible above, so each tap previews on the real text.
]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local Looks = require("quiet_looks")
local Q = require("quiet_ui")
local Sheet = require("quiet_sheet")

local Text = Sheet:extend{ anchor = "bottom" }

local Ticks = Widget:extend{ w = 0, h = 0, count = 8, on = 4 }
function Ticks:getSize() return Geom:new{ w = self.w, h = self.h } end
function Ticks:paintTo(bb, x, y)
    local d, gap = Q.px(20), Q.px(26)
    local total = self.count * d + (self.count - 1) * gap
    local cx = x + math.floor((self.w - total) / 2)
    local cy = y + math.floor((self.h - d) / 2)
    local r = math.floor(d / 2)
    for i = 1, self.count do
        local px_ = cx + (i - 1) * (d + gap)
        Q.fillRound(bb, px_, cy, d, d, Q.INK, r, r, r, r)
        if i > self.on then
            local b = Q.px(3)
            Q.fillRound(bb, px_ + b, cy + b, d - 2 * b, d - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)
        end
    end
end

function Text:stepIndex()
    local size = Looks.currentSize(self.ui)
    local best, idx = math.huge, 1
    for i, s in ipairs(Looks.steps) do
        if math.abs(s - size) < best then best, idx = math.abs(s - size), i end
    end
    return idx
end

-- A taps move the dots at once; the book is re-laid out once, SIZE_SETTLE after the last tap. Each re-layout
-- takes a moment and KOReader ignores taps while it runs, so three quick taps used to land as one or two.
local SIZE_SETTLE = 0.4

function Text:shownStep()
    return self.pending_step or self:stepIndex()
end

function Text:applyPendingSize()
    UIManager:unschedule(self.apply_size)
    local i = self.pending_step
    self.pending_step = nil
    if i and i ~= self:stepIndex() then Looks.setSize(self.ui, Looks.steps[i]) end
end

-- Closing the sheet applies a size still waiting for its SIZE_SETTLE (the last tap counts) instead of leaving a
-- timer behind it, unless the book itself is closing; either way nothing is left scheduled.
function Text:settlePending()
    UIManager:unschedule(self.apply_size)
    if self.pending_step and not (self.plugin and self.plugin.closing_document) then
        self:applyPendingSize()
    end
    self.pending_step = nil
end

function Text:setStep(i)
    i = math.max(1, math.min(i, #Looks.steps))
    if i == self:shownStep() then return end
    self.pending_step = i
    self:refresh()
    UIManager:unschedule(self.apply_size)
    UIManager:scheduleIn(SIZE_SETTLE, self.apply_size)
end

-- A Layout step drawn as a little page: lines of text with this step's margins, spacing or alignment.
local Page = Widget:extend{ w = 0, h = 0, kind = "margins", id = "normal" }
function Page:getSize() return Geom:new{ w = self.w, h = self.h } end
function Page:paintTo(bb, x, y)
    local px = Q.px
    local th = px(7)                                    -- one line of text
    local frame = self.kind == "margins"                -- margins show the page's edge, so the white space reads
    if frame then
        local r, b = px(12), px(3)
        Q.fillRound(bb, x, y, self.w, self.h, Q.LINE, r, r, r, r)
        Q.fillRound(bb, x + b, y + b, self.w - 2 * b, self.h - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)
    end
    local inset = frame and (({ narrow = 0.07, normal = 0.16, wide = 0.28 })[self.id] or 0.16) or 0.1
    local gap = self.kind == "spacing" and (({ tight = px(8), normal = px(14), loose = px(20) })[self.id] or px(14))
        or px(11)
    local widths = { 1, 1, 1, 0.58 }                    -- justified: full lines, a short last one
    if self.kind == "align" and self.id == "left" then widths = { 0.93, 0.74, 0.86, 0.5 } end
    local lx, lw = x + math.floor(self.w * inset), math.floor(self.w * (1 - 2 * inset))
    local total = #widths * th + (#widths - 1) * gap
    local ly = y + math.floor((self.h - total) / 2)
    local r = math.floor(th / 2)
    for i, f in ipairs(widths) do
        Q.fillRound(bb, lx, ly + (i - 1) * (th + gap), math.floor(lw * f), th, Q.INK, r, r, r, r)
    end
end

-- Two or more choices in one pill, the chosen one on a soft pill in bold: the Stats page's week/year switch.
local function segmented(w, h, items, chosen, callback)
    local px = Q.px
    local pad = px(6)
    local seg_w = math.floor((w - 2 * pad) / #items)
    local row = HorizontalGroup:new{ align = "center" }
    for _, it in ipairs(items) do
        local on = it[1] == chosen
        local label = Q.text(it[2], 29, { bold = on, color = on and Q.INK or Q.INK2 })
        local cell = Q.Panel:new{ w = seg_w, h = h - 2 * pad, radii = { 999, 999, 999, 999 }, fill = on and Q.SOFT or nil,
            content = CenterContainer:new{ dimen = Geom:new{ w = seg_w, h = h - 2 * pad }, label } }
        row[#row + 1] = Q.Tap:new{ w = seg_w, h = h - 2 * pad, content = cell, callback = function()
            if not on then callback(it[1]) end
        end }
    end
    return Q.Panel:new{ w = w, h = h, radii = { 999, 999, 999, 999 }, border = Q.LINE, bw = px(3),
        content = CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, row } }
end

-- A tile: the look and Layout tiles' shape, the chosen one outlined darker on a soft fill with its name in bold.
local function tile(w, h, on, top, name, callback)
    local px = Q.px
    local panel = Q.Panel:new{
        w = w, h = h, radii = { 32, 32, 32, 32 },
        border = on and Q.INK2 or Q.LINE, bw = on and px(5) or px(3), fill = on and Q.SOFT or nil,
        content = CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            VerticalGroup:new{ align = "center", top, Q.vspan(8), Q.text(name, 27, { bold = on }) },
        },
    }
    return Q.Tap:new{ w = w, h = h, content = panel, callback = callback }
end

-- Chips that wrap onto as many rows as they need.
local function flow(chips, w, gap)
    local rows, row, used = VerticalGroup:new{ align = "left" }, nil, 0
    for _, c in ipairs(chips) do
        local cw = c:getSize().w
        if not row or used + gap + cw > w then
            if row then rows[#rows + 1] = row; rows[#rows + 1] = Q.vspan(14) end
            row, used = HorizontalGroup:new{ align = "center" }, 0
        else
            row[#row + 1] = Q.hspan(gap)
            used = used + gap
        end
        row[#row + 1] = c
        used = used + cw
    end
    if row then rows[#rows + 1] = row end
    return rows
end

Text.tab = "text" -- the tab the sheet opens on: the last one used

function Text:build()
    self.apply_size = self.apply_size or function() self:applyPendingSize() end
    local W, px = self.W, Q.px
    local inner = W - 2 * px(56)

    local function labelRow(left, right)
        local og = OverlapGroup:new{ dimen = Geom:new{ w = inner, h = px(52) } }
        og[1] = LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(52) }, Q.text(left, 33, { bold = true }) }
        if right then
            og[2] = RightContainer:new{ dimen = Geom:new{ w = inner, h = px(52) }, Q.text(right, 30, { color = Q.INK2 }) }
        end
        return og
    end

    local tabs = segmented(px(560), px(84), { { "text", "Text" }, { "layout", "Layout" } }, Text.tab, function(id)
        Text.tab = id
        self:refresh()
    end)

    local body = VerticalGroup:new{ align = "center" }
    local function add(w) body[#body + 1] = w end

    if Text.tab == "text" then
        local idx = self:shownStep()
        local stepper_h = px(124)
        local side = px(132)
        add(labelRow("Text size", idx .. " of " .. #Looks.steps))
        add(Q.vspan(14))
        add(Q.Panel:new{
            w = inner, h = stepper_h, radii = { 999, 999, 999, 999 }, border = Q.LINE, bw = px(3),
            content = HorizontalGroup:new{
                align = "center",
                Q.Tap:new{ w = side, h = stepper_h, content = Q.text("A", 38, { bold = true }),
                    callback = function() self:setStep(idx - 1) end },
                Ticks:new{ w = inner - 2 * side, h = stepper_h, count = #Looks.steps, on = idx },
                Q.Tap:new{ w = side, h = stepper_h, content = Q.text("A", 66, { bold = true }),
                    callback = function() self:setStep(idx + 1) end },
            },
        })

        local current = Looks.matchLook(self.ui)
        add(Q.vspan(30))
        add(labelRow("Look", current == "custom" and "Custom" or nil))
        add(Q.vspan(14))
        local tile_gap = px(24)
        local tile_w = math.floor((inner - 3 * tile_gap) / 4)
        local tiles = HorizontalGroup:new{ align = "center" }
        local samples = { standard = { 64, false }, compact = { 50, false }, relaxed = { 70, false }, bold = { 64, true } }
        for i, id in ipairs(Looks.order) do
            local sample = samples[id]
            local aa = CenterContainer:new{ dimen = Geom:new{ w = tile_w, h = px(80) },
                TextWidget:new{ text = "Aa", face = Q.serif(sample[1], sample[2]), fgcolor = Q.INK } }
            tiles[#tiles + 1] = tile(tile_w, px(180), id == current, aa, Looks.names[id], function()
                -- the look sets its own size: a size still waiting to apply is dropped
                UIManager:unschedule(self.apply_size)
                self.pending_step = nil
                Looks.apply(self.ui, id) -- the page re-lays out on the next tick
                self:refresh()           -- the new selection shows first
            end)
            if i < #Looks.order then tiles[#tiles + 1] = Q.hspan(tile_gap) end
        end
        add(tiles)

        local fonts = Looks.availableFonts()
        if #fonts > 1 then
            local chosen = Looks.currentFont(self.ui)
            local chips = {}
            for _, f in ipairs(fonts) do
                local on = f.face == chosen
                local label = TextWidget:new{ text = f.label, face = Q.family(f.face, 31), fgcolor = Q.INK }
                local cw, ch = label:getSize().w + px(56), px(84)
                chips[#chips + 1] = Q.Tap:new{ w = cw, h = ch, callback = function()
                    if on then return end
                    Looks.setFont(self.ui, f.face)
                    self:refresh()
                end, content = Q.Panel:new{
                    w = cw, h = ch, radii = { 999, 999, 999, 999 },
                    border = on and Q.INK2 or Q.LINE, bw = on and px(5) or px(3), fill = on and Q.SOFT or nil,
                    content = CenterContainer:new{ dimen = Geom:new{ w = cw, h = ch }, label },
                } }
            end
            add(Q.vspan(30))
            add(labelRow("Font"))
            add(Q.vspan(14))
            local chip_rows = flow(chips, inner, px(16))
            add(LeftContainer:new{ dimen = Geom:new{ w = inner, h = chip_rows:getSize().h }, chip_rows })
        end
    else
        local rows = {
            { "Margins", "margins", Looks.MARGINS },
            { "Spacing", "spacing", Looks.SPACING },
            { "Alignment", "align", Looks.ALIGN },
        }
        for r, row in ipairs(rows) do
            local chosen = Looks.currentStep(self.ui, row[3])
            local n = #row[3]
            local gap = px(24)
            local tw = math.floor((inner - (n - 1) * gap) / n)
            local hg = HorizontalGroup:new{ align = "center" }
            for i, step in ipairs(row[3]) do
                local page = Page:new{ w = math.min(tw - px(48), px(200)), h = px(96), kind = row[2], id = step.id }
                hg[#hg + 1] = tile(tw, px(170), step.id == chosen, page, step.name, function()
                    Looks.setLayout(self.ui, step) -- re-lays out on the next tick
                    self:refresh()
                end)
                if i < n then hg[#hg + 1] = Q.hspan(gap) end
            end
            if r > 1 then add(Q.vspan(30)) end
            add(labelRow(row[1]))
            add(Q.vspan(14))
            add(hg)
        end
    end

    self.content = VerticalGroup:new{
        align = "center",
        Q.vspan(22), Sheet.grip(), Q.vspan(22),
        tabs, Q.vspan(26),
        body,
        Q.vspan(34),
    }
    self.panel_h = self.content:getSize().h + px(6)
    self.content = CenterContainer:new{ dimen = Geom:new{ w = W, h = self.panel_h }, self.content }
end

return Text
