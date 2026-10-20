--[[
More sheet: everything rare, one level down. Claude first (recap, who's who, this page, your own question:
they open Search & Ask),
then page overview, go to, this book, rotate, and at the bottom the full classic KOReader menu.
]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local Q = require("quiet_ui")
local Sheet = require("quiet_sheet")

local More = Sheet:extend{ anchor = "bottom" }

local Divider = Widget:extend{ w = 0 }
function Divider:getSize() return Geom:new{ w = self.w, h = Q.px(2) } end
function Divider:paintTo(bb, x, y) bb:paintRect(x, y, self.w, Q.px(2), Q.TRACK) end

function More:run(fn)
    self:close()
    UIManager:nextTick(fn)
end

function More:event(name, arg)
    self:run(function() self.ui:handleEvent(Event:new(name, arg)) end)
end

function More:ask(opts)
    self:run(function() require("quiet_ask").show(self.plugin, self.ui, opts) end)
end

function More:build()
    local W, px = self.W, Q.px
    local inner = W - 2 * px(56)

    local function row(icon, title, subtitle, cb, dim)
        local text = VerticalGroup:new{ align = "left", Q.text(title, dim and 31 or 35, { color = dim and Q.INK2 or Q.INK }) }
        if subtitle then
            text[#text + 1] = Q.vspan(2)
            text[#text + 1] = Q.text(subtitle, 27, { color = Q.INK2, max_width = inner - px(160) })
        end
        local og = OverlapGroup:new{
            dimen = Geom:new{ w = inner, h = px(136) },
            LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(136) },
                HorizontalGroup:new{ align = "center", Q.icon(icon, 56), Q.hspan(28), text } },
            RightContainer:new{ dimen = Geom:new{ w = inner, h = px(136) }, Q.icon("chevron", 40) },
        }
        return Q.Tap:new{ w = inner, h = px(136), content = og, callback = cb, capsule_radius = 32 }
    end

    local function chip(label, cb)
        local t = Q.text(label, 29)
        local w = t:getSize().w + px(60)
        local panel = Q.Panel:new{ w = w, h = px(88), radii = { 999, 999, 999, 999 }, border = Q.LINE, bw = px(3),
            content = CenterContainer:new{ dimen = Geom:new{ w = w, h = px(88) }, t } }
        return Q.Tap:new{ w = w, h = px(88), content = panel, callback = cb }
    end

    -- the AI this Kindle has, if any (keys.lua): without one the block isn't there
    local okC, C = pcall(require, "quiet_claude")
    local ai_on = okC and type(C) == "table" and C.available and C.available()
    local aiName = ai_on and C.name and C.name() or "Claude"
    local claude = VerticalGroup:new{
        align = "left",
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(70) },
            HorizontalGroup:new{ align = "center", Q.icon("spark", 56), Q.hspan(28),
                Q.text("Ask " .. aiName .. " about this book", 35, { bold = true }) } },
        Q.vspan(12),
        HorizontalGroup:new{
            align = "center",
            Q.hspan(84),
            chip("Recap so far", function() self:ask({ suggest = "recap" }) end), Q.hspan(16),
            chip("Who's who", function() self:ask({ suggest = "whos_who" }) end), Q.hspan(16),
            chip("This page", function() self:ask({ suggest = "explain_page" }) end), Q.hspan(16),
            chip("Ask…", function() self:ask({}) end),
        },
        Q.vspan(10),
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(40) },
            HorizontalGroup:new{ Q.hspan(84), Q.text("Only uses what you've read so far.", 26, { color = Q.INK2 }) } },
    }

    local header = OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = px(70) },
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(70) }, Q.text("More", 35, { bold = true }) },
        RightContainer:new{ dimen = Geom:new{ w = inner, h = px(70) },
            Q.Tap:new{ w = px(90), h = px(70), content = Q.icon("close", 44), callback = function() self:close() end } },
    }

    self.content = VerticalGroup:new{
        align = "center",
        Q.vspan(22), Sheet.grip(), Q.vspan(14), header, Q.vspan(16),
        ai_on and claude or Q.vspan(1), ai_on and Q.vspan(20) or Q.vspan(1), ai_on and Divider:new{ w = inner } or Q.vspan(1),
        row("grid", "Page overview", "Every page as a thumbnail", function() self:event("ShowPageBrowser") end),
        row("goto", "Go to page or percent", nil, function() self:run(function() self.plugin:showGoto() end) end),
        row("info", "This book", "Details, your reading time, pages left", function() self:event("ShowBookStatus") end),
        row("rotate", "Rotate screen", nil, function() self:event("SwapRotation") end),
        Divider:new{ w = inner },
        row("gear", "All KOReader settings", "The full classic menu, for emergencies",
            function() self:run(function() self.ui.menu:onShowMenu() end) end, true),
        Q.vspan(24),
    }
    self.panel_h = self.content:getSize().h + px(6)
    self.content = CenterContainer:new{ dimen = Geom:new{ w = W, h = self.panel_h }, self.content }
end

return More
