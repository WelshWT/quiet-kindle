-- The visible top-right label is a direct, clean exit from Home/Library/Stats.
local PluginLoader = require("pluginloader")
local original = PluginLoader.loadPlugins
PluginLoader.loadPlugins = function(self)
    local enabled, disabled = original(self)
    local ok, Topbar = pcall(require, "screens/sui_topbar")
    if ok and not Topbar._quiet_direct_exit then
        Topbar._quiet_direct_exit = true
        local register = Topbar.registerTouchZones
        Topbar.registerTouchZones = function(plugin, fm)
            register(plugin, fm)
            local Screen = require("device").screen
            local width = Screen:scaleBySize(190)
            fm:registerTouchZones({ {
                id = "quiet_direct_exit", ges = "tap",
                screen_zone = { ratio_x = 1 - width / Screen:getWidth(), ratio_y = 0,
                    ratio_w = width / Screen:getWidth(), ratio_h = Topbar.TOTAL_TOP_H() / Screen:getHeight() },
                overrides = { "filemanager_tap", "filemanager_ext_tap" },
                handler = function()
                    require("quiet_amazon").leaveKOReader(0)
                    return true
                end,
            } })
        end
    end
    return enabled, disabled
end
