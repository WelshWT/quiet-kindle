-- Books Amazon's reader recorded as finished before KOReader took over, so Stats and the Library count them.
-- The list is per Kindle, so it isn't in this repo: it's read from settings/quiet/amazon_finished.lua on the
-- Kindle if there is one, and is empty otherwise. That file returns a list like this (from Amazon's catalog,
-- /var/local/cc.db: read state 1, Amazon's "read", or read state 2 at 100%; last opened = finish date). Same
-- book twice in a year counts once. file: the EPUB copy on the Kindle (its cover, and tap to open); cover:
-- Amazon's own cached cover image, for books that only exist in Amazon's format.
--
--   return {
--       { finished = "2026-03-14", title = "…", author = "…", series = "…", n = 1,
--         file = "/mnt/us/documents/….epub" },
--       { finished = "2026-03-13", title = "…", author = "…", file = nil,
--         cover = "/mnt/us/system/thumbnails/thumbnail_<ASIN>_EBOK_portrait.jpg" },
--   }

local DataStorage = require("datastorage")
local logger = require("logger")

local path = DataStorage:getSettingsDir() .. "/quiet/amazon_finished.lua"
local f = io.open(path, "r")
if not f then return {} end
f:close()
local ok, list = pcall(dofile, path)
if ok and type(list) == "table" then return list end
logger.warn("quietstats: can't read", path, list)
return {}
