--[[
Quiet: the reading UI for a Kindle Paperwhite (design notes: docs/design.md in the repo).
  - tap the top band (22%, as on the Kindle): toolbar with Home and Text, Contents, Notes, Search, More
  - swipe down from the top edge: Light sheet; swipe up from the bottom edge: page overview
  - tap the bottom line: switch it between time left in chapter, time left in book, and page number
  - selecting text: a five-button bar (patched per reader instance, falls back to the stock pop-up)
  - footer: "14 min left in chapter" on the left, percent on the right
KOReader's own menus are untouched and stay reachable under More > All KOReader settings.
]]

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local Q = require("quiet_ui")
local Screen = Device.screen

local Quiet = WidgetContainer:extend{
    name = "quiet",
    is_doc_only = true,
}

local TOP_BAND = 0.22

function Quiet:init()
    Q.icon_dir = self.path .. "/icons/"
    self:registerZones()
    local ok, err = pcall(function() require("quiet_selbar").wrap(self.ui) end)
    if not ok then logger.warn("quiet: selection bar not installed:", err) end
    local okf, errf = pcall(function() require("quiet_finish").attach(self.ui) end)
    if not okf then logger.warn("quiet: finish detection not installed:", errf) end
    self:patchFooter()
    -- the footer cached its text functions when the book opened (before plugins load): rebuild that list
    local footer = self.ui.view and self.ui.view.footer
    if footer and footer.updateFooterTextGenerator then
        pcall(footer.updateFooterTextGenerator, footer)
    end
end

function Quiet:registerZones()
    self.ui:registerTouchZones({
        {
            id = "quiet_top_tap", ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = TOP_BAND },
            overrides = { "readermenu_tap", "readermenu_ext_tap", "tap_forward", "tap_backward",
                "readerconfigmenu_tap", "readerconfigmenu_ext_tap" },
            handler = function(ges) return self:onTopTap(ges) end,
        },
        {
            id = "quiet_top_swipe", ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 / 8 },
            overrides = { "readermenu_swipe", "readermenu_ext_swipe", "paging_swipe", "rolling_swipe" },
            handler = function(ges)
                if ges.direction == "south" then
                    self:showLight()
                    return true
                end
            end,
        },
        {
            id = "quiet_bottom_tap", ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 7 / 8, ratio_w = 1, ratio_h = 1 / 8 },
            overrides = { "readerconfigmenu_tap", "readerconfigmenu_ext_tap", "readerfooter_tap", "tap_forward", "tap_backward" },
            handler = function(ges) return self:onBottomTap(ges) end,
        },
        {
            id = "quiet_bottom_swipe", ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 7 / 8, ratio_w = 1, ratio_h = 1 / 8 },
            overrides = { "readerconfigmenu_swipe", "readerconfigmenu_ext_swipe", "paging_swipe", "rolling_swipe" },
            handler = function(ges)
                if ges.direction == "north" then
                    self.ui:handleEvent(Event:new("ShowPageBrowser"))
                    return true
                end
            end,
        },
    })
end

function Quiet:onTopTap(ges)
    local w, h = Screen:getWidth(), Screen:getHeight()
    -- the top-right corner keeps its bookmark tap, as on the Kindle
    if ges.pos.x > w * 7 / 8 and ges.pos.y < h / 8 then return false end
    self:showToolbar()
    return true
end

function Quiet:onBottomTap(ges)
    local h = Screen:getHeight()
    if ges.pos.y > h - Q.px(80) then
        local modes = { chapter = "book", book = "page", page = "chapter" }
        local mode = G_reader_settings:readSetting("quiet_footer_mode") or "chapter"
        G_reader_settings:saveSetting("quiet_footer_mode", modes[mode] or "chapter")
        self.ui:handleEvent(Event:new("UpdateFooter", true))
        return true
    end
    -- Above the footer line the band turns pages exactly as the rest of the page does: KOReader's own tap_backward
    -- and tap_forward zones decide (their split, custom zones, reading direction, "tap to turn" switched off).
    -- The tap is used up either way, so it never reaches the stock bottom-band menu this zone replaces.
    local zones = self.ui._zones or {}
    for _, id in ipairs({ "tap_backward", "tap_forward" }) do
        local z = zones[id]
        if z and z.gs_range and z.gs_range:match(ges) then
            z.handler(ges)
            return true
        end
    end
    return true
end

-- Footer: our words instead of KOReader's prefixed items ("⤻ 14m", "⇥ 2%").
function Quiet:patchFooter()
    local ok, ReaderFooter = pcall(require, "apps/reader/modules/readerfooter")
    if not ok or not ReaderFooter.textGeneratorMap or ReaderFooter._quiet then return end
    ReaderFooter._quiet = true
    local map = ReaderFooter.textGeneratorMap
    local Toolbar = require("quiet_toolbar")
    map.chapter_time_to_read = function(footer)
        local ok2, pos = pcall(Toolbar.position, footer.ui)
        if not ok2 then return "" end
        local mode = G_reader_settings:readSetting("quiet_footer_mode") or "chapter"
        if mode == "page" then
            return string.format("Page %d of %d", pos.page, pos.total)
        elseif mode == "book" then
            local ok_rt, info = pcall(function() return require("quiet_readtime").forUI(footer.ui) end)
            if ok_rt and info and info.left_secs then
                if info.left_secs <= 0 then return "End of the story" end
                return require("quiet_readtime").format(math.max(60, info.left_secs)) .. " left in book"
            end
            local left = footer.ui.document:getTotalPagesLeft(pos.page)
            return left .. " pages left in book"
        end
        return pos.chapter_left or ""
    end
    map.percentage = function(footer)
        return string.format("%d%%", math.floor((footer.percent_finished or 0) * 100 + 0.5))
    end
end

function Quiet:goHome()
    if not self.ui:handleEvent(Event:new("SimpleUIGoHomescreen")) then
        self.ui:handleEvent(Event:new("Home"))
    end
end

function Quiet:showToolbar()
    if self.toolbar then return end
    local Toolbar = require("quiet_toolbar")
    local ok, t = pcall(function() return Toolbar:new{ plugin = self, ui = self.ui } end)
    if not ok then
        logger.warn("quiet: toolbar failed, showing the classic menu:", t)
        self.ui.menu:onShowMenu()
        return
    end
    self.toolbar = t
    UIManager:show(t, "ui")
end

function Quiet:closeToolbar()
    local t = self.toolbar
    if not t then return end
    self.toolbar = nil
    UIManager:close(t, "ui", t:panelRegion())
end

function Quiet:showSheet(module_name)
    if self.sheet then self:closeSheet(self.sheet) end
    local ok, s = pcall(function() return require(module_name):new{ plugin = self, ui = self.ui } end)
    if not ok then
        logger.warn("quiet: sheet failed:", module_name, s)
        return
    end
    self.sheet = s
    UIManager:show(s, "ui")
end

function Quiet:closeSheet(s)
    if self.sheet == s then self.sheet = nil end
    UIManager:close(s, "ui", s.dimen)
end

function Quiet:showText() self:showSheet("quiet_text") end
function Quiet:showLight() self:showSheet("quiet_light") end
function Quiet:showMore() self:showSheet("quiet_more") end
function Quiet:showGoto() self:showSheet("quiet_goto") end

function Quiet:onSetDimensions()
    self:closeToolbar()
    if self.sheet then self:closeSheet(self.sheet) end
end

-- The Text sheet's settings are one set for every book, as on a Kindle: KOReader's modules have just saved this
-- book's font and layout into its own settings (they handle SaveSettings before plugins); dropping them again means
-- the book opens with every book's settings next time. Reflowable books only: a PDF keeps its own.
function Quiet:onSaveSettings()
    local ds = self.ui and self.ui.doc_settings
    if not (ds and self.ui.rolling) then return end
    for _, key in ipairs(require("quiet_looks").GLOBAL_KEYS) do ds:delSetting(key) end
end

function Quiet:onCloseDocument()
    self.closing_document = true -- sheets closing now must not change the book (quiet_text's pending size)
    pcall(function() require("quiet_net").cancelAll() end)
    pcall(function() require("quiet_bookctx").forget() end)
    self:closeToolbar()
    if self.sheet then self:closeSheet(self.sheet) end
end

return Quiet
