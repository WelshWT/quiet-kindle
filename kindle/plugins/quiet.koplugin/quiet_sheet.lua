--[[
Base for the Text, Light and More sheets: a rounded panel anchored to the bottom (or top) edge, over the page.
Tap the page or swipe the sheet back toward its edge to close it. Subclasses implement build() and set
self.content and self.panel_h.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Q = require("quiet_ui")
local Screen = Device.screen

local Sheet = InputContainer:extend{ plugin = nil, ui = nil, anchor = "bottom" }

function Sheet:init()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self:rebuild()
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeSheet = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
end

function Sheet:rebuild()
    self:build()
    local R = Q.R_SHEET
    self.panel = Q.Panel:new{
        w = self.W, h = self.panel_h,
        radii = self.anchor == "bottom" and { R, R, 0, 0 } or { 0, 0, R, R },
        border = Q.LINE, bw = Q.px(3), content = self.content,
    }
end

-- Redraw after a change (a new value, a toggle), in place. A closed sheet stays closed: a refresh scheduled
-- before it went (the Wi-Fi tile's, a light change) does nothing.
function Sheet:refresh()
    if self.closed then return end
    local old_h, old = self.panel_h, self.panel_region
    self:rebuild()
    if old_h and self.panel_h ~= old_h then
        -- a shorter (or taller) panel, e.g. another tab of the Text sheet: the page under the part it gave up is
        -- repainted too, or the old panel's edge stays on the screen
        UIManager:setDirty("all", function()
            local new = self.panel_region
            return "ui", old and new and old:combine(new) or new or old
        end)
    else
        UIManager:setDirty(self, function() return "ui", self.panel_region end)
    end
end

function Sheet:getSize() return Geom:new{ w = self.W, h = self.H } end

function Sheet:paintTo(bb, x, y)
    local b = Q.px(3)
    if self.anchor == "bottom" then
        local top = self.H - self.panel_h + b
        self.panel:paintTo(bb, -b, top)
        self.panel_region = Geom:new{ x = 0, y = top, w = self.W, h = self.panel_h - b }
    else
        self.panel:paintTo(bb, -b, -b)
        self.panel_region = Geom:new{ x = 0, y = 0, w = self.W, h = self.panel_h - b }
    end
end

function Sheet:handleEvent(ev)
    if ev.handler == "onCloseWidget" then self:settle() end
    if self.panel and self.panel:handleEvent(ev) then return true end
    return InputContainer.handleEvent(self, ev)
end

-- However it closes (tap outside, swipe, another sheet, the book closing, rotation), a sheet is marked closed once,
-- and a subclass's settlePending() deals with whatever it had scheduled, so nothing it started acts on the reader
-- after it's gone.
function Sheet:settle()
    if self.closed then return end
    self.closed = true
    if self.settlePending then self:settlePending() end
end

function Sheet:close()
    self.plugin:closeSheet(self)
end

function Sheet:onTapOutside(_, ges)
    if not (self.panel_region and ges.pos:intersectWith(self.panel_region)) then self:close() end
    return true
end

function Sheet:onSwipeSheet(_, ges)
    if (self.anchor == "bottom" and ges.direction == "south") or (self.anchor == "top" and ges.direction == "north") then
        self:close()
    end
    return true
end

function Sheet:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function Sheet:onClose()
    self:close()
    return true
end

-- Small helpers shared by the sheets.
function Sheet.grip()
    local Widget = require("ui/widget/widget")
    local G = Widget:extend{}
    function G:getSize() return Geom:new{ w = Q.px(120), h = Q.px(10) } end
    function G:paintTo(bb, x, y)
        local r = math.floor(Q.px(10) / 2)
        Q.fillRound(bb, x, y, Q.px(120), Q.px(10), Q.TRACK, r, r, r, r)
    end
    return G:new{}
end

return Sheet
