--[[
The Stats page as a SimpleUI module, shown alone on a SimpleUI custom screen ("cs_qstats", made by change file
013-stats-page) that the Stats tab opens. It fills the space between SimpleUI's status row and its tab bar.
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {
    id = "quiet_stats",
    name = "Stats (Quiet)",
    label = nil,
    default_on = false,
}

M.SCREEN_ID = "cs_qstats"
M.PFX = "simpleui_cs_qstats_"

local state = { view = "week" }
local current -- the view built last: SimpleUI builds a new one on every visit

-- Only on its own screen, never on Home.
function M.isEnabled(pfx) return pfx == M.PFX end

local function height()
    local ok, UI = pcall(require, "infra/sui_core")
    if not ok then return require("device").screen:getHeight() end
    -- the last card ends a card gap above the tab bar's hairline (the bar has no frame of its own since change 030)
    return UI.getContentHeight() - UI.MOD_GAP - require("device").screen:scaleBySize(14)
end

function M.getHeight() return height() end

function M.build(w)
    local ok, data = pcall(function() return require("qs_data").collect() end)
    if not ok then
        logger.warn("quietstats: no data:", data)
        return nil
    end
    local View = require("qs_view")
    local view
    view = View:new{
        w = w, h = height(), view = state.view, data = data,
        on_switch = function(v)
            state.view = v
            view.view = v
            view:redraw()
        end,
        on_open = function(file)
            UIManager:nextTick(function()
                require("apps/reader/readerui"):showReader(file)
            end)
        end,
    }
    -- a late redraw (covers arriving) only happens while this view is the one built last and its screen is on
    -- top: the screen's id alone also matches a newer view of the same screen
    view.is_visible = function()
        if current ~= view then return false end
        local ok_e, Engine = pcall(require, "engines/sui_screen_engine")
        local inst = ok_e and Engine.getInstance and Engine.getInstance(M.SCREEN_ID)
        return inst ~= nil and UIManager:getTopmostVisibleWidget() == inst
    end
    current = view
    return view
end

function M.getMenuItems() return nil end

return M
