--[[
Quiet stats: the Stats tab's page (streak, this week, the book being read, reading days, this year).
Registers one module with SimpleUI; change file 013-stats-page puts it on its own screen behind the Stats tab.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local QuietStats = WidgetContainer:extend{
    name = "quietstats",
    is_doc_only = false,
}

local registered = false

function QuietStats:init()
    if registered then return end
    local ok, Registry = pcall(require, "modules/moduleregistry")
    if ok and Registry and Registry.register then
        Registry.register(require("qs_module"))
        registered = true
    else
        logger.warn("quietstats: SimpleUI module registry not found")
    end
end

return QuietStats
