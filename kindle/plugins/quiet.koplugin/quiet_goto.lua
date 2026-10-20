--[[
Go to page (tap "Page 9 of 579" on the toolbar, or More > Go to page or percent): a big readout, a keypad with
big keys, three quick places and one Go button. "40" then % (or % then "40") means 40% of the book.

Page numbers are the ones the toolbar shows (Toolbar.position: the rendered pages of the book), and a percent
lands on the page the toolbar would call that percent, so what you type is where you arrive. Every jump is put
on KOReader's location stack first, so the toolbar offers "Back to page N" afterwards.

Typing past the end does nothing to the number; the readout says "there's no page 600" instead. Hold ⌫ to clear.
Only the readout, the Go button and the % key are refreshed on a key press, not the whole sheet.
]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local Q = require("quiet_ui")
local Sheet = require("quiet_sheet")

local Goto = Sheet:extend{ anchor = "bottom" }

-- What the keys have typed so far, and what it means. No KOReader in here.
local Input = {}
Input.__index = Input
Goto.Input = Input

function Input.new(cur, total)
    total = math.max(1, total or 1)
    return setmetatable({ cur = cur or 1, total = total, digits = "", percent = false, refused = nil }, Input)
end

-- The toolbar shows floor(page / total * 100 + 0.5)% of the book; these two agree with it.
function Input.percentForPage(page, total)
    return math.floor(page / total * 100 + 0.5)
end

function Input.pageForPercent(pct, total)
    return math.max(1, math.min(total, math.floor(pct / 100 * total + 0.5)))
end

-- key: "0"…"9", "%", "del", "clear"
function Input:press(key)
    self.refused = nil
    if key == "del" then
        if self.digits ~= "" then
            self.digits = self.digits:sub(1, -2)
        else
            self.percent = false
        end
    elseif key == "clear" then
        self.digits, self.percent = "", false
    elseif key == "%" then
        local n = tonumber(self.digits)
        if self.percent then
            -- back to pages: the number stays if it is a page
            if n and (n < 1 or n > self.total) then self.digits = "" end
            self.percent = false
        elseif n and n > 100 then
            self.refused = self.digits .. "%"
        else
            self.percent = true
        end
    elseif key:match("^%d$") then
        local digits = self.digits == "0" and key or self.digits .. key
        if digits == "0" and not self.percent then return self end -- there is no page 0
        if tonumber(digits) > (self.percent and 100 or self.total) then
            self.refused = self.percent and (digits .. "%") or ("page " .. digits)
        else
            self.digits = digits
        end
    end
    return self
end

-- The page a Go would land on, or nil.
function Input:target()
    local n = tonumber(self.digits)
    if not n then return nil end
    if self.percent then return Input.pageForPercent(n, self.total) end
    if n >= 1 and n <= self.total then return n end
end

-- What the readout and the button say. Before anything is typed, the readout shows where you are, in grey.
function Input:view()
    local n = tonumber(self.digits)
    local v = { placeholder = n == nil }
    if self.percent then
        v.big = (n or Input.percentForPage(self.cur, self.total)) .. "%"
        v.small = "page " .. (n and Input.pageForPercent(n, self.total) or self.cur)
    else
        v.big = tostring(n or self.cur)
        v.small = "of " .. self.total
    end
    if self.refused then v.small = v.small .. " · there's no " .. self.refused end
    local t = self:target()
    v.enabled = t ~= nil
    v.button = t and ("Go to page " .. t) or "Go to page"
    return v
end

-- The big number and what it is ("120  of 579"), on a thin line. Painted from the sheet's input each time.
local Readout = Widget:extend{ sheet = nil, w = 0 }

function Readout:init()
    local probe = TextWidget:new{ text = "0", face = Q.serif(110, true) }
    self.text_h = probe:getSize().h
    probe:free()
    self.h = self.text_h + Q.px(6 + 3)
end

function Readout:getSize() return Geom:new{ w = self.w, h = self.h } end

function Readout:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local v = self.sheet.input:view()
    local gap = Q.px(18)
    local big = TextWidget:new{ text = v.big, face = Q.serif(110, true), fgcolor = v.placeholder and Q.INK2 or Q.INK }
    local bw = big:getSize().w
    local small = TextWidget:new{ text = v.small, face = Q.face(32), fgcolor = Q.INK2,
        max_width = math.max(Q.px(100), self.w - bw - gap) }
    local sw = small:getSize().w
    local bx = x + math.max(0, math.floor((self.w - bw - gap - sw) / 2))
    big:paintTo(bb, bx, y)
    local baseline = y + big:getBaseline()
    small:paintTo(bb, bx + bw + gap, baseline - small:getBaseline())
    big:free()
    small:free()
    bb:paintRect(x, y + self.h - Q.px(3), self.w, Q.px(3), Q.LINE)
end

-- A keypad key: a rounded outline with a label or icon; `on` (a function) gives it the soft selected look.
local KeyFace = Widget:extend{ w = 0, h = 0, content = nil, on = nil }

function KeyFace:getSize() return Geom:new{ w = self.w, h = self.h } end

function KeyFace:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local on = self.on and self.on()
    local r, b = Q.px(28), on and Q.px(5) or Q.px(3)
    Q.fillRound(bb, x, y, self.w, self.h, on and Q.INK2 or Q.LINE, r, r, r, r)
    Q.fillRound(bb, x + b, y + b, self.w - 2 * b, self.h - 2 * b, on and Q.SOFT or Q.PAPER, r - b, r - b, r - b, r - b)
    local s = self.content:getSize()
    self.content:paintTo(bb, x + math.floor((self.w - s.w) / 2), y + math.floor((self.h - s.h) / 2))
end

-- The Go button: a black pill when there is somewhere to go, an outline until then.
local GoFace = Widget:extend{ sheet = nil, w = 0, h = 0 }

function GoFace:getSize() return Geom:new{ w = self.w, h = self.h } end

function GoFace:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local v = self.sheet.input:view()
    local r = math.floor(self.h / 2)
    if v.enabled then
        Q.fillRound(bb, x, y, self.w, self.h, Q.INK, r, r, r, r)
    else
        local b = Q.px(3)
        Q.fillRound(bb, x, y, self.w, self.h, Q.LINE, r, r, r, r)
        Q.fillRound(bb, x + b, y + b, self.w - 2 * b, self.h - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)
    end
    local t = TextWidget:new{ text = v.button, face = Q.face(33, true), fgcolor = v.enabled and Q.PAPER or Q.INK2 }
    local s = t:getSize()
    t:paintTo(bb, x + math.floor((self.w - s.w) / 2), y + math.floor((self.h - s.h) / 2))
    t:free()
end

-- Where the toolbar says you are: page and page count (the toolbar's own helper, so the two always agree).
local function where(ui)
    return require("quiet_toolbar").currentPage(ui), ui.document:getPageCount()
end

-- Chapter start, Beginning, Next chapter, each with its page; a place the book doesn't have is left out.
function Goto:places()
    local toc, cur = self.ui.toc, self.input.cur
    local start, nxt
    if toc then
        pcall(function()
            start = toc:isChapterStart(cur) and cur or toc:getPreviousChapter(cur)
            nxt = toc:getNextChapter(cur)
        end)
    end
    local list = {}
    if start then list[#list + 1] = { "Chapter start", start } end
    list[#list + 1] = { "Beginning", 1 }
    if nxt then list[#list + 1] = { "Next chapter", nxt } end
    return list
end

function Goto:go(page)
    if not page then return end
    self:close()
    if page == self.input.cur then return end
    local ui = self.ui
    UIManager:nextTick(function()
        if ui.link then ui.link:addCurrentLocationToStack() end
        ui:handleEvent(Event:new("GotoPage", page))
    end)
end

-- A key press: change the input, then refresh only what shows it.
function Goto:press(key)
    local was = self.input.percent
    self.input:press(key)
    local parts = { self.readout, self.go_face }
    if self.input.percent ~= was then parts[#parts + 1] = self.pct_face end
    for _, w in ipairs(parts) do
        if w.dimen then UIManager:setDirty(self, function() return "ui", w.dimen end) end
    end
end

function Goto:build()
    local W, px = self.W, Q.px
    local inner = W - 2 * px(56)
    self.input = self.input or Input.new(where(self.ui))

    local header = OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = px(70) },
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(70) }, Q.text("Go to page", 35, { bold = true }) },
        RightContainer:new{ dimen = Geom:new{ w = inner, h = px(70) },
            Q.text("you're on " .. self.input.cur, 31, { color = Q.INK2 }) },
    }

    self.readout = Readout:new{ sheet = self, w = inner }

    local gap, key_h = px(16), px(116)
    local key_w = math.floor((inner - 2 * gap) / 3)
    local function key(k)
        local face = KeyFace:new{ w = key_w, h = key_h,
            content = k == "del" and Q.icon("backspace", 52) or Q.text(k, 46) }
        if k == "%" then
            face.on = function() return self.input.percent end
            self.pct_face = face
        end
        -- a slow press counts as a press (hold ⌫ clears)
        return Q.Tap:new{ w = key_w, h = key_h, content = face,
            callback = function() self:press(k) end,
            hold_callback = function() self:press(k == "del" and "clear" or k) end }
    end
    local rows = { { "1", "2", "3" }, { "4", "5", "6" }, { "7", "8", "9" }, { "%", "0", "del" } }
    local keypad = VerticalGroup:new{ align = "center" }
    for i, keys in ipairs(rows) do
        local row = HorizontalGroup:new{ align = "center" }
        for j, k in ipairs(keys) do
            row[#row + 1] = key(k)
            if j < #keys then row[#row + 1] = Q.hspan(16) end
        end
        keypad[#keypad + 1] = row
        if i < #rows then keypad[#keypad + 1] = Q.vspan(16) end
    end

    local chips = HorizontalGroup:new{ align = "center" }
    for i, place in ipairs(self:places()) do
        local t = Q.text(place[1], 27)
        local w = t:getSize().w + px(60)
        local panel = Q.Panel:new{ w = w, h = px(80), radii = { 999, 999, 999, 999 }, border = Q.LINE, bw = px(3),
            content = CenterContainer:new{ dimen = Geom:new{ w = w, h = px(80) }, t } }
        if i > 1 then chips[#chips + 1] = Q.hspan(14) end
        local function jump() self:go(place[2]) end
        chips[#chips + 1] = Q.Tap:new{ w = w, h = px(80), content = panel, callback = jump, hold_callback = jump }
    end

    self.go_face = GoFace:new{ sheet = self, w = inner, h = px(112) }
    local function go_now() self:go(self.input:target()) end
    local go = Q.Tap:new{ w = inner, h = px(112), content = self.go_face, callback = go_now, hold_callback = go_now }

    self.content = VerticalGroup:new{
        align = "center",
        Q.vspan(22), Sheet.grip(), Q.vspan(18),
        header, Q.vspan(12),
        self.readout, Q.vspan(24),
        keypad, Q.vspan(22),
        chips, Q.vspan(22),
        go, Q.vspan(30),
    }
    self.panel_h = self.content:getSize().h + px(6)
    self.content = CenterContainer:new{ dimen = Geom:new{ w = W, h = self.panel_h }, self.content }
end

return Goto
