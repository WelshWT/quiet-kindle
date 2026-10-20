--[[
Quiet home: Amazon's side of the Kindle, from KOReader.
  - qh_store: the books only Amazon's reader opens (from Amazon's catalogue), and opening one (quiet_amazon)
  - qh_library: those books in the Library, among the others (hooked in by patches/2-quiet-library.lua)
  - qh_sheets: the Library's Store sheet (Amazon's store and home) and the sheet for holding one of those books
  - qh_card: Home's old "Kindle Store books" card, still registered as a SimpleUI module but off since change 024
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local QuietHome = WidgetContainer:extend{
    name = "quiethome",
    is_doc_only = false,
}

local registered = false

function QuietHome:init()
    if registered then return end
    local ok, Registry = pcall(require, "modules/moduleregistry")
    if ok and Registry and Registry.register then
        local ok2, err = pcall(Registry.register, require("qh_card"))
        if ok2 then
            registered = true
        else
            logger.warn("quiethome: card not registered:", err)
        end
    else
        logger.warn("quiethome: SimpleUI module registry not found")
    end
end

return QuietHome
