--[[
The reading toolbar (tap the top band): "<- Home" and five labelled buttons on top, the book's title under them,
and at the bottom where you are: chapter, page, time left, and a scrubber with previous/next chapter.
Tap the page (anywhere outside the two panels) to put it away.
]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local datetime = require("datetime")
local Q = require("quiet_ui")
local Screen = Device.screen

local Toolbar = InputContainer:extend{ plugin = nil, ui = nil }

local function minutesText(mins)
    if mins < 60 then return string.format("%d min", mins) end
    local h, m = math.floor(mins / 60), mins % 60
    return m > 0 and string.format("%d h %d min", h, m) or string.format("%d h", h)
end

-- The page the reader is on. Reflowable books (EPUB…) ask their document; page-image ones (PDF, DjVu, CBZ) keep
-- it in ReaderPaging, and their document has no getCurrentPage().
function Toolbar.currentPage(ui)
    if ui.paging then return ui.paging.current_page end
    return ui.document:getCurrentPage()
end

-- Where the reader is, as plain words. Shared with the footer and the Go to page keypad.
function Toolbar.position(ui)
    local doc = ui.document
    local page = Toolbar.currentPage(ui)
    local total = doc:getPageCount()
    local info = { page = page, total = total, pct = total > 0 and page / total or 0 }
    info.chapter = ui.toc and ui.toc:getTocTitleByPage(page) or ""
    local left = ui.toc and ui.toc:getChapterPagesLeft(page, true) or doc:getTotalPagesLeft(page)
    local ok_rt, avg = pcall(function() return require("quiet_readtime").pace(ui) end)
    if not ok_rt or not avg then avg = ui.statistics and ui.statistics.avg_time end
    if left and avg and avg > 0 then
        info.chapter_left = minutesText(math.max(1, math.ceil(left * avg / 60))) .. " left in chapter"
    elseif left then
        info.chapter_left = left == 1 and "1 page left in chapter" or (left .. " pages left in chapter")
    end
    return info
end

function Toolbar:init()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self:build()
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeToolbar = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
end

function Toolbar:act(fn)
    self.plugin:closeToolbar()
    UIManager:nextTick(fn)
end

function Toolbar:event(name, arg)
    self:act(function() self.ui:handleEvent(Event:new(name, arg)) end)
end

function Toolbar:build()
    local W, H, px = self.W, self.H, Q.px
    local ui = self.ui
    local pos = Toolbar.position(ui)
    local inner = W - 2 * px(56)

    -- status row: time · light handle · Wi-Fi and battery
    local time = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    local right = HorizontalGroup:new{ align = "center" }
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr:isWifiOn() then
        right[#right + 1] = Q.icon("wifi", 40)
        right[#right + 1] = Q.hspan(14)
    end
    local powerd = Device:getPowerDevice()
    right[#right + 1] = Q.text((powerd and powerd:getCapacity() or 0) .. "%", 31)
    local handle = Q.Tap:new{ w = px(160), h = px(84), content = Q.icon("down", 44),
        callback = function() self:act(function() self.plugin:showLight() end) end }
    local status = OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = px(84) },
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(84) }, Q.text(time, 31) },
        CenterContainer:new{ dimen = Geom:new{ w = inner, h = px(84) }, handle },
        RightContainer:new{ dimen = Geom:new{ w = inner, h = px(84) }, right },
    }

    -- tool row: <- Home on the left, five labelled buttons on the right
    local home = Q.Tap:new{
        w = px(250), h = px(118),
        content = HorizontalGroup:new{ align = "center", Q.icon("back", 52), Q.hspan(14), Q.text("Home", 40, { bold = true }) },
        callback = function() self:act(function() self.plugin:goHome() end) end,
    }
    local function tool(icon, label, cb)
        return Q.Tap:new{ w = px(140), h = px(140), content = Q.iconLabel(icon, label), callback = cb }
    end
    local tools = HorizontalGroup:new{
        align = "center",
        tool("Aa", "Text", function() self:act(function() self.plugin:showText() end) end),
        tool("contents", "Contents", function() self:event("ShowToc") end),
        tool("notes", "Notes", function() self:event("ShowBookmark") end),
        tool("search", "Search", function() self:act(function() require("quiet_ask").show(self.plugin, self.ui, {}) end) end),
        tool("more", "More", function() self:act(function() self.plugin:showMore() end) end),
    }
    local toolrow = OverlapGroup:new{
        dimen = Geom:new{ w = W - px(60), h = px(150) },
        LeftContainer:new{ dimen = Geom:new{ w = W - px(60), h = px(150) }, home },
        RightContainer:new{ dimen = Geom:new{ w = W - px(60), h = px(150) }, tools },
    }

    -- title row
    local props = ui.doc_props or {}
    local title = props.display_title or props.title or ""
    local author = props.authors and props.authors:gsub("\n", ", ") or nil
    local titlerow = HorizontalGroup:new{ align = "center", Q.text(title, 33, { bold = true, max_width = inner * 0.66 }) }
    if author and author ~= "" then
        titlerow[#titlerow + 1] = Q.text("  ·  " .. author, 31, { color = Q.INK2, max_width = inner * 0.34 })
    end

    local top_content = VerticalGroup:new{
        align = "left",
        CenterContainer:new{ dimen = Geom:new{ w = W, h = px(84) }, status },
        LeftContainer:new{ dimen = Geom:new{ w = W, h = px(150) },
            HorizontalGroup:new{ Q.hspan(30), toolrow } },
        LeftContainer:new{ dimen = Geom:new{ w = W, h = px(64) },
            HorizontalGroup:new{ Q.hspan(56), titlerow } },
    }
    local top_h = px(84 + 150 + 64 + 26)
    self.top = Q.Panel:new{ w = W, h = top_h, radii = { 0, 0, Q.R_SHEET, Q.R_SHEET },
        border = Q.LINE, bw = px(3), content = top_content }

    -- bottom: chapter and page, time left, scrubber
    local l1 = OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = px(56) },
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(56) },
            Q.text(pos.chapter ~= "" and pos.chapter or " ", 37, { bold = true, max_width = inner * 0.62 }) },
        RightContainer:new{ dimen = Geom:new{ w = inner, h = px(56) }, self:pageLink(pos) },
    }
    local l2 = OverlapGroup:new{ dimen = Geom:new{ w = inner, h = px(50) } }
    local detail = (pos.chapter_left and (pos.chapter_left .. "  ·  ") or "") .. math.floor(pos.pct * 100 + 0.5) .. "% of the book"
    l2[#l2 + 1] = LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(50) }, Q.text(detail, 30, { color = Q.INK2 }) }
    local back = self:backLink()
    if back then
        l2[#l2 + 1] = RightContainer:new{ dimen = Geom:new{ w = inner, h = px(50) }, back }
    end
    local track = Q.Track:new{
        w = inner - 2 * px(118), h = px(118), value = pos.pct, track_h = 8, knob = 46,
        on_set = function(v) self:jump(function() Toolbar.scrubTo(self.ui, v) end) end,
    }
    local scrub = HorizontalGroup:new{
        align = "center",
        Q.Tap:new{ w = px(118), h = px(118), content = Q.icon("prev", 52),
            callback = function() self:jump(function() self.ui:handleEvent(Event:new("GotoPrevChapter")) end) end },
        track,
        Q.Tap:new{ w = px(118), h = px(118), content = Q.icon("next", 52),
            callback = function() self:jump(function() self.ui:handleEvent(Event:new("GotoNextChapter")) end) end },
    }
    local bottom_content = VerticalGroup:new{
        align = "center",
        Q.vspan(26), l1, l2, Q.vspan(4), scrub, Q.vspan(26),
    }
    local bottom_h = px(26 + 56 + 50 + 4 + 118 + 26) + px(10)
    self.bottom = Q.Panel:new{ w = W, h = bottom_h, radii = { Q.R_SHEET, Q.R_SHEET, 0, 0 },
        border = Q.LINE, bw = px(3), content = bottom_content, pad_x = px(56) }
end

-- "Page 9 of 579": tap it for the Go to page keypad (text stays flush right).
function Toolbar:pageLink(pos)
    local t = Q.text(string.format("Page %d of %d", pos.page, pos.total), 33)
    local w, h = t:getSize().w + Q.px(48), Q.px(56)
    return Q.Tap:new{
        w = w, h = h, content = RightContainer:new{ dimen = Geom:new{ w = w, h = h }, t },
        callback = function() self:act(function() self.plugin:showGoto() end) end,
    }
end

-- The page a ReaderLink location stands for: reflowable books keep an xpointer, page-image books (PDF…) the view
-- state of each visible page, the first one's page being the page.
function Toolbar.locationPage(ui, loc)
    if type(loc) ~= "table" then return nil end
    if loc.xpointer then
        local ok, page = pcall(ui.document.getPageFromXPointer, ui.document, loc.xpointer)
        return ok and page or nil
    end
    local first = loc[1]
    return type(first) == "table" and first.page or nil
end

-- Where KOReader's Back (ReaderLink:onGoBackLink) will take you: it passes over a last entry that is where you
-- already are and goes to the one before. nil when Back would go nowhere, false when it goes somewhere whose
-- page can't be told.
function Toolbar.backPage(ui)
    local link = ui.link
    local stack = link and link.location_stack
    if not stack or #stack == 0 then return nil end
    local i = #stack
    local ok, same = pcall(link.compareLocationToCurrent, link, stack[i])
    if ok and same then i = i - 1 end
    if not stack[i] then return nil end
    return Toolbar.locationPage(ui, stack[i]) or false
end

-- A scrub is a jump: where it started goes on the location stack first, as KOReader's own chapter, contents and
-- page-overview jumps do (GotoPercent alone doesn't), so Back returns there. A scrub that didn't move (by
-- ReaderLink's own test, the one Back uses: same xpointer, or same page for page-image books; a same-page move in
-- scroll mode is a move) takes that entry off again and leaves the forward history as it was.
function Toolbar.scrubTo(ui, v)
    local link = ui.link
    local stack, forward = link and link.location_stack, link and link.forward_location_stack
    local depth = stack and #stack
    if link then link:addCurrentLocationToStack() end
    ui:handleEvent(Event:new("GotoPercent", v * 100))
    if stack and link.location_stack == stack and #stack == depth + 1 then
        local ok, same = pcall(link.compareLocationToCurrent, link, stack[#stack])
        if ok and same then
            table.remove(stack)
            link.forward_location_stack = forward
        end
    end
end

-- "Back to page N" after a jump (links, contents, search, scrubber): a link, never a pop-up; only when Back
-- would go somewhere, and naming where.
function Toolbar:backLink()
    local page = Toolbar.backPage(self.ui)
    if page == nil then return nil end
    local label = page and ("Back to page " .. page) or "Back"
    return Q.Tap:new{
        w = Q.px(300), h = Q.px(50),
        content = HorizontalGroup:new{ align = "center", Q.icon("back", 34), Q.hspan(8), Q.text(label, 30, { bold = true }) },
        callback = function() self:jump(function() self.ui:handleEvent(Event:new("GoBackLink", true)) end) end,
    }
end

-- Navigate, then rebuild the panels in place so the toolbar shows the new position.
function Toolbar:jump(fn)
    fn()
    UIManager:nextTick(function()
        if self.plugin.toolbar ~= self then return end
        self:build()
        UIManager:setDirty(self, "ui")
    end)
end

function Toolbar:getSize() return Geom:new{ w = self.W, h = self.H } end

function Toolbar:paintTo(bb, x, y)
    local b = Q.px(3)
    self.top:paintTo(bb, -b, -b)
    self.top.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.top.h - b }
    self.bottom:paintTo(bb, -b, self.H - self.bottom.h + b)
    self.bottom.dimen = Geom:new{ x = 0, y = self.H - self.bottom.h + b, w = self.W, h = self.bottom.h - b }
end

function Toolbar:panelRegion()
    return Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
end

function Toolbar:handleEvent(ev)
    if self.top and self.top:handleEvent(ev) then return true end
    if self.bottom and self.bottom:handleEvent(ev) then return true end
    return InputContainer.handleEvent(self, ev)
end

function Toolbar:onTapOutside(_, ges)
    local inside = (self.top.dimen and ges.pos:intersectWith(self.top.dimen))
        or (self.bottom.dimen and ges.pos:intersectWith(self.bottom.dimen))
    if not inside then self.plugin:closeToolbar() end
    return true
end

function Toolbar:onSwipeToolbar(_, ges)
    if ges.direction == "south" and self.top.dimen and ges.pos:intersectWith(self.top.dimen) then
        self:act(function() self.plugin:showLight() end)
    else
        self.plugin:closeToolbar()
    end
    return true
end

function Toolbar:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function Toolbar:onClose()
    self.plugin:closeToolbar()
    return true
end

return Toolbar
