--[[
Selection bar: five buttons instead of KOReader's 13 — Highlight, Note, Ask Claude, Look up, More — in one rounded
bar just below the selection (above it when there's no room). Highlight, Note and Look up run the stock buttons'
own actions, so they behave the same; Ask Claude opens Search & Ask with the selection as the focus; More opens
the stock pop-up. Existing highlights and PDFs keep the stock pop-up.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Q = require("quiet_ui")
local Screen = Device.screen

local Bar = InputContainer:extend{ hl = nil, index = nil, orig = nil }

local ITEMS = {
    { key = "02_highlight", icon = "highlight", label = "Highlight" },
    { key = "04_add_note", icon = "note", label = "Note" },
    { key = "quiet_ask", icon = "spark", label = "Ask Claude", bold = true, own = true },
    { key = "06_dictionary", icon = "lookup", label = "Look up" }, -- gitleaks:allow (a menu key, not a secret)
}

function Bar:init()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    local px = Q.px
    local bar_w = self.W - 2 * px(60)
    local cell = math.floor((bar_w - 2 * px(10)) / 5)
    local row = HorizontalGroup:new{ align = "center" }
    local hl = self.hl
    -- Ask is there when the Kindle has an AI (keys.lua), named after it; without one the bar is a button shorter
    local okC, C = pcall(require, "quiet_claude")
    local ai_on = okC and type(C) == "table" and C.available and C.available()
    local shown = 1 -- More
    for _, item in ipairs(ITEMS) do
        local fn = hl._highlight_buttons[item.key]
        if (fn or item.own) and (item.key ~= "quiet_ask" or ai_on) then
            shown = shown + 1
            local label = item.key == "quiet_ask" and ("Ask " .. (C.name and C.name() or "Claude")) or item.label
            row[#row + 1] = Q.Tap:new{
                w = cell, h = px(132), capsule_radius = 36,
                content = Q.iconLabel(item.icon, label, { label_px = 26, bold = item.bold }),
                callback = function() if item.own then self:ask() else self:run(item.key) end end,
            }
        end
    end
    row[#row + 1] = Q.Tap:new{
        w = cell, h = px(132),
        content = Q.iconLabel("more", "More", { label_px = 26 }),
        callback = function() self:more() end,
    }
    bar_w = shown * cell + 2 * px(10)
    self.bar_h = px(150)
    self.panel = Q.Panel:new{ w = bar_w, h = self.bar_h, radii = { 44, 44, 44, 44 }, border = Q.LINE, bw = px(3),
        content = row, pad_x = px(10), pad_y = px(9) }
    self.bar_w = bar_w
    self.bar_y = self:placement()
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

-- Below the selection if it fits, otherwise above, otherwise near the bottom.
function Bar:placement()
    local px = Q.px
    local st = self.hl.selected_text
    local boxes = st and (st.sboxes or st.pboxes)
    local gap = px(24)
    if boxes and #boxes > 0 then
        local top, bottom = math.huge, 0
        for _, b in ipairs(boxes) do
            top = math.min(top, b.y)
            bottom = math.max(bottom, b.y + b.h)
        end
        if bottom + gap + self.bar_h <= self.H - px(20) then return bottom + gap end
        if top - gap - self.bar_h >= px(20) then return top - gap - self.bar_h end
    end
    return self.H - self.bar_h - px(80)
end

function Bar:getSize() return Geom:new{ w = self.W, h = self.H } end

function Bar:paintTo(bb, x, y)
    local bx = math.floor((self.W - self.bar_w) / 2)
    self.panel:paintTo(bb, bx, self.bar_y)
    self.bar_region = Geom:new{ x = bx, y = self.bar_y, w = self.bar_w, h = self.bar_h }
end

function Bar:handleEvent(ev)
    if self.panel and self.panel:handleEvent(ev) then return true end
    return InputContainer.handleEvent(self, ev)
end

function Bar:dismiss()
    if self.hl.highlight_dialog == self then self.hl.highlight_dialog = nil end
    UIManager:close(self, "ui", self.bar_region)
end

function Bar:run(key)
    local hl, index = self.hl, self.index
    local fn = hl._highlight_buttons[key]
    self:dismiss()
    if not fn then return end
    local ok, err = pcall(function()
        local spec = fn(hl, index)
        if spec and spec.callback then spec.callback() end
    end)
    if not ok then logger.warn("quiet selbar:", key, err) end
end

-- Ask Claude: Search & Ask with the selection as the focus (the selection stays until the sheet closes).
function Bar:ask()
    local hl, ui = self.hl, self.hl.ui
    local st = hl.selected_text or {}
    local page
    pcall(function()
        if type(st.pos0) == "string" then page = ui.document:getPageFromXPointer(st.pos0)
        elseif type(st.pos0) == "table" then page = st.pos0.page end
    end)
    self:dismiss()
    if not ui.quiet then return end
    require("quiet_ask").show(ui.quiet, ui, { focus_text = st.text, focus_page = page,
        on_close = function() if hl.selected_text then hl:clear() end end })
end

function Bar:more()
    local hl, index, orig = self.hl, self.index, self.orig
    self:dismiss()
    UIManager:nextTick(function() orig(hl, index) end)
end

function Bar:onTapOutside(_, ges)
    if not (self.bar_region and ges.pos:intersectWith(self.bar_region)) then
        self:dismiss()
        if self.hl.hold_pos then self.hl:clear() end
    end
    return true
end

function Bar:onClose()
    self:dismiss()
    return true
end

local M = {}

function M.wrap(ui)
    local hl = ui.highlight
    if not hl or hl._quiet_wrapped then return end
    hl._quiet_wrapped = true
    local orig = hl.onShowHighlightMenu
    hl.onShowHighlightMenu = function(this, index)
        if index ~= nil or not this.selected_text or this.ui.paging then
            return orig(this, index)
        end
        local ok, err = pcall(function()
            local bar = Bar:new{ hl = this, index = index, orig = orig }
            this.highlight_dialog = bar
            UIManager:show(bar, "ui", bar.dimen)
        end)
        if not ok then
            logger.warn("quiet selbar, falling back:", err)
            return orig(this, index)
        end
        return true
    end
end

return M
