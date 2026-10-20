--[[
Quiet home pull-down: on Home, Library and Stats, a tap on the top edge or a swipe down from it opens the same
Light sheet as in a book (brightness, warmth, Auto, Wi-Fi, Night, Rotate, Sleep), instead of KOReader's classic
file-manager menu with its tab strip and segmented sliders. That menu is one tap further, under "All KOReader
settings" at the bottom of the sheet.
]]

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local host = { sheet = nil }

function host:closeSheet(s)
    if self.sheet == s then self.sheet = nil end
    UIManager:close(s, "ui", s.dimen)
end

local function showLight(menu)
    if host.sheet then return true end
    local ok, Light = pcall(require, "quiet_light")
    if not ok then
        logger.warn("quiet home: light sheet unavailable", Light)
        return false
    end
    local ok2, sheet = pcall(function()
        return Light:new{ plugin = host, ui = menu.ui, classic_menu = function() menu:onShowMenu() end }
    end)
    if not ok2 then
        logger.warn("quiet home: light sheet failed", sheet)
        return false
    end
    host.sheet = sheet
    UIManager:show(sheet, "ui")
    return true
end

local onTapShowMenu, onSwipeShowMenu = FileManagerMenu.onTapShowMenu, FileManagerMenu.onSwipeShowMenu

function FileManagerMenu:onTapShowMenu(ges)
    if showLight(self) then return true end
    return onTapShowMenu(self, ges)
end

function FileManagerMenu:onSwipeShowMenu(ges)
    if ges and ges.direction == "south" and showLight(self) then return true end
    return onSwipeShowMenu(self, ges)
end
