--[[
The Stats page, drawn in the Quiet shape system (rounded cards, pills, four grey steps the e-ink shows clearly).

  This week: the streak and the last seven days as a chain, minutes per day against last week, the book being
             read with time left and a finish date, and six months of reading days.
  This year: books finished, books per month, a wall of their covers, and three highlights.

Design and research: "Stats" in docs/design.md.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Q = require("quiet_ui")
local Data = require("qs_data")

if not Q.icon_dir and package.searchpath then
    local p = package.searchpath("quiet_ui", package.path)
    if p then Q.icon_dir = p:gsub("quiet_ui%.lua$", "") .. "icons/" end
end

local px = Q.px
local HEAT = { Blitbuffer.gray(0.2), Blitbuffer.gray(0.42), Blitbuffer.gray(0.7), Blitbuffer.COLOR_BLACK }
local LAST_WEEK = Blitbuffer.gray(0.2)
local GAP = 18

local function duration(secs)
    local mins = math.floor((secs or 0) / 60 + 0.5)
    if mins < 60 then return mins .. " min" end
    local h, m = math.floor(mins / 60), mins % 60
    return m > 0 and string.format("%d h %d min", h, m) or (h .. " h")
end

local function heatLevel(secs)
    if secs <= 0 then return 0 end
    if secs < 15 * 60 then return 1 end
    if secs < 45 * 60 then return 2 end
    if secs < 90 * 60 then return 3 end
    return 4
end

-- Paper-coloured corner masks, so a square image gets the same rounded corners as every cover.
local function roundCorners(bb, x, y, w, h, r, color)
    for row = 0, r - 1 do
        local yy = r - row - 0.5
        local inset = math.floor(r - math.sqrt(math.max(0, r * r - yy * yy)) + 0.5)
        if inset > 0 then
            bb:paintRect(x, y + row, inset, 1, color)
            bb:paintRect(x + w - inset, y + row, inset, 1, color)
            bb:paintRect(x, y + h - 1 - row, inset, 1, color)
            bb:paintRect(x + w - inset, y + h - 1 - row, inset, 1, color)
        end
    end
end

local function card(bb, x, y, w, h)
    local r, b = px(32), px(3)
    Q.fillRound(bb, x, y, w, h, Q.LINE, r, r, r, r)
    Q.fillRound(bb, x + b, y + b, w - 2 * b, h - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)
end

local function paintText(bb, str, size, x, y, opts)
    local tw = Q.text(str, size, opts)
    local sz = tw:getSize()
    local align = opts and opts.align
    if align == "right" then x = x - sz.w elseif align == "center" then x = x - math.floor(sz.w / 2) end
    tw:paintTo(bb, x, y)
    local w, h = sz.w, sz.h
    tw:free()
    return w, h
end

local function paintSerif(bb, str, size, x, y, bold, max_width)
    local tw = TextWidget:new{ text = str, face = Q.serif(size, bold), fgcolor = Q.INK, max_width = max_width }
    local sz = tw:getSize()
    local base = tw:getBaseline()
    tw:paintTo(bb, x, y)
    tw:free()
    return sz.w, sz.h, base
end

local function paintIcon(bb, name, size, x, y)
    local icon = IconWidget:new{ file = Q.icon_dir .. name .. ".svg", width = px(size), height = px(size), alpha = true }
    icon:paintTo(bb, x, y)
    icon:free()
end

-- Covers, scaled to fill a tile (cropped in the middle), kept for the life of KOReader. A cover KOReader hasn't
-- extracted yet (the library only extracts what it has shown) is queued in `missing` and fetched in the background.
local covers = {}
local missing = {}
local function coverFor(file, w, h)
    if not file then return nil end
    local k = file .. "|" .. w .. "x" .. h
    if covers[k] ~= nil then return covers[k] or nil end
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok then return nil end
    local ok2, info = pcall(BookInfoManager.getBookInfo, BookInfoManager, file, true)
    if not ok2 then return nil end
    if not info or not info.cover_bb then
        -- never catalogued (the library hasn't shown it yet), or catalogued without a cover
        if not info or not info.cover_fetched then missing[file] = true else covers[k] = false end
        return nil
    end
    local src = info.cover_bb
    local sw, sh = src:getWidth(), src:getHeight()
    local f = math.max(w / sw, h / sh)
    local tw, th = math.max(w, math.ceil(sw * f)), math.max(h, math.ceil(sh * f))
    local RenderImage = require("ui/renderimage")
    local scaled = RenderImage:scaleBlitBuffer(src, tw, th)
    local out = Blitbuffer.new(w, h, scaled:getType())
    out:blitFrom(scaled, 0, 0, math.floor((tw - w) / 2), math.floor((th - h) / 2), w, h)
    scaled:free()
    src:free()
    covers[k] = out
    return out
end

-- A cover from an image file (Amazon's cached covers for its own books).
local function coverFromImage(path, w, h)
    if not path then return nil end
    local k = path .. "|" .. w .. "x" .. h
    if covers[k] ~= nil then return covers[k] or nil end
    covers[k] = false
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local RenderImage = require("ui/renderimage")
    local ok, src = pcall(RenderImage.renderImageFile, RenderImage, path, false)
    if not ok or not src then return nil end
    local sw, sh = src:getWidth(), src:getHeight()
    local f = math.max(w / sw, h / sh)
    local tw, th = math.max(w, math.ceil(sw * f)), math.max(h, math.ceil(sh * f))
    local scaled = RenderImage:scaleBlitBuffer(src, tw, th)
    local out = Blitbuffer.new(w, h, scaled:getType())
    out:blitFrom(scaled, 0, 0, math.floor((tw - w) / 2), math.floor((th - h) / 2), w, h)
    scaled:free()
    src:free()
    covers[k] = out
    return out
end

-- The view on screen is the one painted last. When covers arrive (the year's wall, or the book in hand on This
-- week), only it repaints, and only while it's still mounted: an older view's own callback would paint its stale
-- page over the view that replaced it, whose tap targets are different.
local live
local function coversReady()
    local v = live
    if v and v.is_visible and v.is_visible() then v:redraw() end
end

local extracting = false
local function fetchMissingCovers(on_done)
    if extracting or next(missing) == nil then return end
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok then return end
    local files = {}
    for file in pairs(missing) do
        files[#files + 1] = { filepath = file, cover_specs = { max_cover_w = px(300), max_cover_h = px(450) } }
    end
    missing = {}
    if not BookInfoManager:extractInBackground(files) then return end
    extracting = true
    local function check()
        if BookInfoManager:isExtractingInBackground() then
            UIManager:scheduleIn(1, check)
            return
        end
        extracting = false
        on_done()
    end
    UIManager:scheduleIn(2, check)
end

local StatsView = InputContainer:extend{
    w = 0, h = 0,
    view = "week",     -- or "year"
    data = nil,
    on_switch = nil,   -- function(view)
    on_open = nil,     -- function(file)
}

function StatsView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        TapStats = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
    self.targets = {}
end

function StatsView:getSize() return Geom:new{ w = self.w, h = self.h } end

-- Tap targets are recorded while painting, relative to the widget.
function StatsView:target(x, y, w, h, fn)
    self.targets[#self.targets + 1] = { x = x, y = y, w = w, h = h, fn = fn }
end

function StatsView:onTapStats(_, ges)
    local rx, ry = ges.pos.x - self.dimen.x, ges.pos.y - self.dimen.y
    for _, t in ipairs(self.targets) do
        if rx >= t.x and rx < t.x + t.w and ry >= t.y and ry < t.y + t.h then
            t.fn()
            return true
        end
    end
    return true
end

function StatsView:paintTo(bb, x, y)
    live = self
    self.dimen.x, self.dimen.y = x, y
    self.targets = {}
    bb:paintRect(x, y, self.w, self.h, Q.PAPER)
    local ok, err = pcall(function()
        local top = self:paintHeader(bb, x, y)
        if self.view == "year" then
            self:paintYear(bb, x, y, top)
        else
            self:paintWeek(bb, x, y, top)
        end
    end)
    if not ok then logger.warn("quietstats: paint failed:", err) end
end

-- Redraw in place: only this widget changed, so paint it straight to the screen and refresh its area.
function StatsView:redraw()
    local bb = require("device").screen.bb
    self:paintTo(bb, self.dimen.x, self.dimen.y)
    UIManager:setDirty(nil, "ui", self.dimen)
end

function StatsView:paintHeader(bb, x, y)
    local hh = px(120)
    local _, th = paintSerif(bb, "Stats", 58, x + px(8), y, true)
    local sy = y + math.floor((th - px(84)) / 2)
    local sw, sh = px(460), px(84)
    local sx = x + self.w - sw
    local r = math.floor(sh / 2)
    Q.fillRound(bb, sx, sy, sw, sh, Q.LINE, r, r, r, r)
    local b = px(3)
    Q.fillRound(bb, sx + b, sy + b, sw - 2 * b, sh - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)
    local half = math.floor((sw - 2 * px(6)) / 2)
    local inner_h = sh - 2 * px(6)
    local ir = math.floor(inner_h / 2)
    local labels = { { "week", "This week" }, { "year", "This year" } }
    for i, l in ipairs(labels) do
        local hx = sx + px(6) + (i - 1) * half
        local on = self.view == l[1]
        if on then Q.fillRound(bb, hx, sy + px(6), half, inner_h, Q.SOFT, ir, ir, ir, ir) end
        local tw = Q.text(l[2], 28, { bold = on, color = on and Q.INK or Q.INK2 })
        local tsz = tw:getSize()
        tw:paintTo(bb, hx + math.floor((half - tsz.w) / 2), sy + px(6) + math.floor((inner_h - tsz.h) / 2))
        tw:free()
        self:target(hx - x, sy - y, half, sh, function()
            if not on and self.on_switch then self.on_switch(l[1]) end
        end)
    end
    return y + math.max(hh, th + px(16))
end

function StatsView:paintWeek(bb, x, y, top)
    local d = self.data
    local w = self.w
    local cy = top + px(4)

    -- streak
    local sh = px(280)
    card(bb, x, cy, w, sh)
    local nw, _, nbase = paintSerif(bb, tostring(d.streak), 140, x + px(40), cy + px(10), true)
    paintText(bb, d.streak == 1 and "day in a row" or "days in a row", 30, x + px(42), cy + px(10) + nbase + px(22), { bold = true })
    local cx0, cx1 = x + math.max(px(330), px(40) + nw + px(40)), x + w - px(36)
    local dot = px(60)
    local step = (cx1 - cx0 - dot) / 6
    local dy = cy + px(56)
    for i, c in ipairs(d.chain) do
        local dx = math.floor(cx0 + (i - 1) * step)
        local r = math.floor(dot / 2)
        if c.state == "read" then
            Q.fillRound(bb, dx, dy, dot, dot, Q.INK, r, r, r, r)
        elseif c.state == "rest" then
            -- forgiven quiet day: a broken ring
            Q.fillRound(bb, dx, dy, dot, dot, Q.INK2, r, r, r, r)
            Q.fillRound(bb, dx + px(5), dy + px(5), dot - px(10), dot - px(10), Q.PAPER, r - px(5), r - px(5), r - px(5), r - px(5))
            bb:paintRect(dx + r - px(3), dy, px(6), dot, Q.PAPER)
            bb:paintRect(dx, dy + r - px(3), dot, px(6), Q.PAPER)
        else
            local ring = c.state == "today" and Q.INK or Q.LINE
            local bw = c.state == "today" and px(6) or px(4)
            Q.fillRound(bb, dx, dy, dot, dot, ring, r, r, r, r)
            Q.fillRound(bb, dx + bw, dy + bw, dot - 2 * bw, dot - 2 * bw, Q.PAPER, r - bw, r - bw, r - bw, r - bw)
        end
        paintText(bb, c.letter, 25, dx + r, dy + dot + px(8), { align = "center", color = Q.INK2, bold = c.state == "today" })
    end
    local sub
    if d.streak == 0 then
        sub = d.best > 0 and string.format("Read a page to start a new one · best %d", d.best) or "Read a page to start one"
    else
        sub = string.format("Best %d %s", d.best, d.best == 1 and "day" or "days")
        if d.weeks > 0 then sub = sub .. string.format(" · %d %s in a row", d.weeks, d.weeks == 1 and "week" or "weeks") end
    end
    paintText(bb, sub, 27, cx0, dy + dot + px(56), { color = Q.INK2 })
    cy = cy + sh + px(GAP)

    -- this week against last week
    local wh = px(300)
    card(bb, x, cy, w, wh)
    local headline = d.this_total > 0 and (duration(d.this_total) .. " this week") or "A fresh week"
    paintText(bb, headline, 36, x + px(30), cy + px(22), { bold = true })
    if d.last_total > 0 then
        paintText(bb, "last week " .. duration(d.last_total), 27, x + w - px(30), cy + px(30), { align = "right", color = Q.INK2 })
    end
    local bx0, bx1 = x + px(30), x + w - px(30)
    local gap = px(26)
    local cw = math.floor((bx1 - bx0 - 6 * gap) / 7)
    local area_top, area_h = cy + px(84), px(150)
    local maxv = 30 * 60
    for i = 1, 7 do maxv = math.max(maxv, d.this_week[i], d.last_week[i]) end
    local today_idx = (os.date("*t", d.today).wday + 5) % 7 + 1
    local letters = { "M", "T", "W", "T", "F", "S", "S" }
    for i = 1, 7 do
        local bxx = bx0 + (i - 1) * (cw + gap)
        local lh = math.floor(area_h * d.last_week[i] / maxv)
        if lh > 0 then
            local r = math.min(px(14), math.floor(lh / 2), math.floor(cw / 2))
            Q.fillRound(bb, bxx, area_top + area_h - lh, cw, lh, LAST_WEEK, r, r, px(4), px(4))
        end
        local th_ = math.floor(area_h * d.this_week[i] / maxv)
        if th_ > 0 then
            local inset = px(16)
            local r = math.min(px(14), math.floor(th_ / 2), math.floor((cw - 2 * inset) / 2))
            Q.fillRound(bb, bxx + inset, area_top + area_h - th_, cw - 2 * inset, th_, Q.INK, r, r, px(4), px(4))
        end
        bb:paintRect(bxx, area_top + area_h, cw, px(2), Q.LINE)
        paintText(bb, letters[i], 25, bxx + math.floor(cw / 2), area_top + area_h + px(10),
            { align = "center", color = i == today_idx and Q.INK or Q.INK2, bold = i == today_idx })
    end
    cy = cy + wh + px(GAP)

    -- the book being read
    local bh = px(170)
    card(bb, x, cy, w, bh)
    local book = d.book
    if book then
        local cw_, ch_ = px(92), px(138)
        local cover = coverFor(book.file, cw_, ch_)
        local tx = x + px(28)
        if cover then
            bb:blitFrom(cover, tx, cy + px(16), 0, 0, cw_, ch_)
            roundCorners(bb, tx, cy + px(16), cw_, ch_, px(10), Q.PAPER)
            tx = tx + cw_ + px(28)
        end
        local maxw = x + w - px(36) - tx
        paintSerif(bb, book.title, 36, tx, cy + px(22), true, maxw)
        local pw, ph = maxw, px(12)
        local pr = math.floor(ph / 2)
        Q.fillRound(bb, tx, cy + px(86), pw, ph, Q.TRACK, pr, pr, pr, pr)
        local fw = math.floor(pw * math.max(0, math.min(book.pct, 1)))
        if fw > 0 then Q.fillRound(bb, tx, cy + px(86), math.max(fw, ph), ph, Q.INK, pr, pr, pr, pr) end
        local meta
        if book.secs_left < 60 then
            meta = "Almost done"
        else
            meta = duration(book.secs_left) .. " left"
            if book.finish then
                meta = meta .. " · at your pace, done around " .. os.date("%d %b", book.finish):gsub("^0", "")
            end
        end
        paintText(bb, meta, 27, tx, cy + px(112), { color = Q.INK2 })
        self:target(0, cy - y, w, bh, function() if self.on_open then self.on_open(book.file) end end)
    else
        paintText(bb, "Open a book and it shows up here", 30, x + px(30), cy + px(64), { color = Q.INK2 })
    end
    cy = cy + bh + px(GAP)

    -- reading days, six months
    local ch = y + self.h - cy
    card(bb, x, cy, w, ch)
    paintText(bb, "Your reading days", 32, x + px(30), cy + px(20), { bold = true })
    local first = d.first_day and Data.parse(d.first_day)
    local since = first and first > d.heat_start and ("since " .. os.date("%d %B", first):gsub("^0", "")) or nil
    if since then paintText(bb, since, 27, x + w - px(30), cy + px(26), { align = "right", color = Q.INK2 }) end
    local weeks = math.floor(#d.heat / 7)
    local cell = math.min(px(30), math.floor((ch - px(150)) / 7) - px(6))
    local hg, vg = px(7), px(6)
    local gw = weeks * cell + (weeks - 1) * hg
    local gx = x + math.floor((w - gw) / 2)
    local gy = cy + px(108)
    local labels = {}
    for wk = 0, weeks - 1 do
        local monday = Data.addDays(d.heat_start, wk * 7)
        if wk == 0 or tonumber(os.date("%d", monday)) <= 7 then labels[#labels + 1] = { wk, os.date("%b", monday) } end
    end
    if labels[2] and labels[2][1] - labels[1][1] < 3 then table.remove(labels, 1) end
    for _, l in ipairs(labels) do
        paintText(bb, l[2], 23, gx + l[1] * (cell + hg), gy - px(34), { color = Q.INK2 })
    end
    for wk = 0, weeks - 1 do
        for dd = 0, 6 do
            local v = d.heat[wk * 7 + dd + 1]
            if v >= 0 then
                local cx = gx + wk * (cell + hg)
                local cyy = gy + dd * (cell + vg)
                local r = px(8)
                local lvl = heatLevel(v)
                if lvl == 0 then
                    Q.fillRound(bb, cx, cyy, cell, cell, Q.SOFT, r, r, r, r)
                    Q.fillRound(bb, cx + px(2), cyy + px(2), cell - px(4), cell - px(4), Q.PAPER, r - px(2), r - px(2), r - px(2), r - px(2))
                else
                    Q.fillRound(bb, cx, cyy, cell, cell, HEAT[lvl], r, r, r, r)
                end
            end
        end
    end
    -- the book in hand's cover, if it isn't catalogued yet (coverFor queued it)
    fetchMissingCovers(coversReady)
end

function StatsView:paintYear(bb, x, y, top)
    local d = self.data
    local w = self.w
    local cy = top + px(4)

    -- the number and books per month
    local yh = px(330)
    card(bb, x, cy, w, yh)
    local count = #d.books
    local nw, _, nbase = paintSerif(bb, tostring(count), 140, x + px(40), cy + px(30), true)
    paintText(bb, (count == 1 and "book in " or "books in ") .. d.year, 30, x + px(42), cy + px(30) + nbase + px(22), { bold = true })
    local mx0, mx1 = x + math.max(px(330), px(40) + nw + px(50)), x + w - px(36)
    local mgap = px(12)
    local mw = math.floor((mx1 - mx0 - 11 * mgap) / 12)
    local mtop, mh = cy + px(70), px(180)
    local maxm = 1
    for m = 1, 12 do maxm = math.max(maxm, d.per_month[m]) end
    local letters = { "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" }
    for m = 1, 12 do
        local bxx = mx0 + (m - 1) * (mw + mgap)
        local v = d.per_month[m]
        if m > d.month_now then
            Q.fillRound(bb, bxx, mtop + mh - px(8), mw, px(8), Q.SOFT, px(4), px(4), px(4), px(4))
        elseif v == 0 then
            Q.fillRound(bb, bxx, mtop + mh - px(6), mw, px(6), Q.TRACK, px(3), px(3), px(3), px(3))
        else
            local bh = math.max(px(12), math.floor(mh * v / maxm))
            local r = math.min(px(10), math.floor(mw / 2))
            Q.fillRound(bb, bxx, mtop + mh - bh, mw, bh, Q.INK, r, r, px(4), px(4))
            paintText(bb, tostring(v), 24, bxx + math.floor(mw / 2), mtop + mh - bh - px(34), { align = "center" })
        end
        paintText(bb, letters[m], 24, bxx + math.floor(mw / 2), mtop + mh + px(10),
            { align = "center", color = m == d.month_now and Q.INK or Q.INK2, bold = m == d.month_now })
    end
    cy = cy + yh + px(GAP)

    -- the wall of covers: the latest 16, oldest first
    local wh = px(490)
    card(bb, x, cy, w, wh)
    local cols, gap = 8, px(14)
    local tw_ = math.floor((w - px(60) - (cols - 1) * gap) / cols)
    local th_ = math.floor(tw_ * 1.5)
    local shown = {}
    for i = math.max(1, count - 15), count do shown[#shown + 1] = d.books[i] end
    if count == 0 then
        paintText(bb, "Finish a book and its cover lands here", 30, x + px(30), cy + px(60), { color = Q.INK2 })
    end
    for i, b in ipairs(shown) do
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        local tx = x + px(30) + col * (tw_ + gap)
        local ty = cy + px(28) + row * (th_ + gap)
        local cover = coverFor(b.file, tw_, th_) or coverFromImage(b.cover, tw_, th_)
        if cover then
            bb:blitFrom(cover, tx, ty, 0, 0, tw_, th_)
            roundCorners(bb, tx, ty, tw_, th_, px(9), Q.PAPER)
        else
            local r = px(9)
            Q.fillRound(bb, tx, ty, tw_, th_, Q.LINE, r, r, r, r)
            Q.fillRound(bb, tx + px(2), ty + px(2), tw_ - px(4), th_ - px(4), Q.SOFT, r - px(2), r - px(2), r - px(2), r - px(2))
            local box = TextBoxWidget:new{
                text = b.title, face = Q.serif(19, true), width = tw_ - px(12), alignment = "center",
                height = th_ - px(20), height_overflow_show_ellipsis = true, fgcolor = Q.INK,
            }
            local bh = box:getSize().h
            box:paintTo(bb, tx + px(6), ty + math.floor((th_ - bh) / 2))
            box:free()
        end
        if b.file then
            self:target(tx - x, ty - y, tw_, th_, function() if self.on_open then self.on_open(b.file) end end)
        end
    end
    if count > #shown then
        paintText(bb, string.format("and %d earlier", count - #shown), 27, x + px(30), cy + wh - px(52), { color = Q.INK2 })
    end
    fetchMissingCovers(coversReady)
    cy = cy + wh + px(GAP)

    -- highlights
    local hh = y + self.h - cy
    card(bb, x, cy, w, hh)
    if #d.highlights == 0 then
        paintText(bb, "Highlights appear as you finish books", 30, x + px(30), cy + px(40), { color = Q.INK2 })
        return
    end
    local row_h = math.floor((hh - px(36)) / 3)
    for i, hl in ipairs(d.highlights) do
        if i > 3 then break end
        local ry = cy + px(18) + (i - 1) * row_h
        paintIcon(bb, hl.icon, 52, x + px(30), ry + math.floor((row_h - px(52)) / 2))
        paintText(bb, hl.title, 31, x + px(110), ry + math.floor(row_h / 2) - px(42), { bold = true })
        paintText(bb, hl.text, 28, x + px(110), ry + math.floor(row_h / 2) + px(2), { color = Q.INK2, max_width = w - px(140) })
    end
end

StatsView._coversReady = coversReady -- for tests

return StatsView
