--[[
Amazon's books in the Library. Asked for: "make the kindle store books show in the library with maybe some kind of
marker that its from amazon and gonna open up in amazons reader".

The books only Amazon's reader opens (qh_store.amazonBooks) join the Library as virtual entries; nothing is
written to documents/. patches/2-quiet-library.lua adds them where KOReader builds the Library's item table, so
they sort with the real books (named "Title - Author", as Kindle Shelf names files), and answers KOReader's and
CoverBrowser's questions about them from Amazon's catalogue (title, author, cover, progress). This module holds
what it needs:

  - itemsFor(fc, collate) / searchItems(...): the entries, registered by their (made-up) path
  - book(path), listInfo(path), bookInfo(path, get_cover): what an entry is, as KOReader and CoverBrowser ask
  - paintBadge(): the marker on their covers, a link-out arrow on a dark disc (the conventional "opens
    elsewhere" sign), plus in the list the words "Opens in Amazon's reader"
  - open(book) / hold(book): a tap opens the book in Amazon's reader; a hold shows where it opens (qh_sheets),
    never KOReader's file menu (delete, rename and the like make no sense for them)
]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local L = {}

local virtual = {} -- made-up path -> book (qh_store record)

local data_dir = DataStorage.getFullDataDir and DataStorage:getFullDataDir() or DataStorage:getDataDir()
local function iconPath(name) return data_dir .. "/icons/quiet/" .. name .. ".svg" end

function L.book(path) return path and virtual[path] or nil end

-- Characters Kindle Shelf replaces in file names.
local function fileSafe(s)
    return (tostring(s or ""):gsub('[\\/:*?"<>|]', "_"))
end

function L.homeDir()
    local home = G_reader_settings:readSetting("home_dir")
    if not home then
        local ok, fmu = pcall(require, "apps/filemanager/filemanagerutil")
        home = ok and fmu.getHomeFolder and fmu.getHomeFolder() or nil
    end
    return home and (home:gsub("/+$", "")) or nil
end

local function makeItem(fc, collate, dir, book)
    local name = fileSafe(book.title) .. " - " .. fileSafe(book.authors ~= "" and book.authors or "Amazon")
    -- the ASIN keeps two editions with the same title and author apart
    local path = dir .. "/" .. name .. " (" .. book.asin .. ").kfx"
    virtual[path] = book
    -- a file's dates: last read is when Amazon's reader last opened it, created and modified when it was downloaded
    local when = book.last_opened or 0
    local added = book.added or when
    local item = {
        text = name .. ".kfx",
        path = path,
        is_file = true,
        attr = { mode = "file", size = lfs.attributes(book.path, "size") or 0, modification = added, access = when,
            change = added },
        quiet_amazon = book,
    }
    local okBD, BD = pcall(require, "ui/bidi")
    if okBD then item.bidi_wrap_func = BD.filename end
    if collate and collate.item_func then pcall(collate.item_func, item, fc and fc.ui) end
    -- what the percent sorts look at, from Amazon's progress
    item.opened = book.pct ~= nil or book.finished
    item.percent_finished = book.pct or 0
    item.sort_percent = book.finished and 1 or (book.pct or -1)
    item.suffix = "kfx"
    local ok_m, mandatory = false, nil
    if collate and collate.mandatory_func then ok_m, mandatory = pcall(collate.mandatory_func, item) end
    item.mandatory = ok_m and mandatory or "Kindle Store"
    return item
end

local function amazonBooks()
    local ok, Store = pcall(require, "qh_store")
    if not ok then return {} end
    local ok2, books = pcall(Store.amazonBooks)
    if not ok2 or type(books) ~= "table" then
        logger.warn("quiethome: no Amazon books for the Library:", books)
        return {}
    end
    return books
end

-- The Library's entries for Amazon's books, as FileChooser:getListItem() would make them for real files.
function L.itemsFor(fc, collate)
    local home = L.homeDir()
    if not home then return {} end
    local items = {}
    for _, book in ipairs(amazonBooks()) do
        items[#items + 1] = makeItem(fc, collate, home, book)
    end
    return items
end

-- File search: the same entries, kept when their name matches as a file name would (FileSearcher's rules: "*"
-- is everything, * and ? are wildcards, case-insensitive unless asked, with KOReader's Unicode-aware lowering so
-- "éclair" finds "ÉCLAIR" as it does for real files; review C6 cold read).
local function lower(s)
    local ok, util = pcall(require, "util")
    if ok and util.stringLower then
        local ok2, low = pcall(util.stringLower, s)
        if ok2 and low then return low end
    end
    return s:lower()
end

function L.searchItems(fc, collate, search_string, case_sensitive)
    if not search_string or search_string == "" then return {} end
    local pattern
    if search_string ~= "*" then
        pattern = case_sensitive and search_string or lower(search_string)
        pattern = pattern:gsub("%.", "%%."):gsub("%*", ".*"):gsub("%?", ".")
    end
    local found = {}
    for _, item in ipairs(L.itemsFor(fc, collate)) do
        local name = case_sensitive and item.text or lower(item.text)
        local ok, hit = true, pattern == nil
        if pattern then ok, hit = pcall(string.find, name, pattern) end
        if ok and hit then found[#found + 1] = item end
    end
    return found
end

-- KOReader's per-book cache entry (BookList.getBookInfo): opened, status and progress, from Amazon's.
function L.listInfo(path)
    local book = virtual[path]
    if not book then return nil end
    local opened = book.pct ~= nil or book.finished
    return {
        been_opened = opened,
        status = book.finished and "complete" or (opened and "reading" or nil),
        percent_finished = book.pct,
        rating = 0,
        has_annotations = false,
        quiet_amazon = book,
    }
end

-- Amazon's cover image, decoded once and kept (as greys) for the life of KOReader. Never freed by callers.
local sources = {}
local function coverSource(path)
    if not path then return nil end
    if sources[path] ~= nil then return sources[path] or nil end
    sources[path] = false
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local RenderImage = require("ui/renderimage")
    local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, path, false)
    if not ok or not bb then
        logger.warn("quiethome: Amazon cover not readable:", path)
        return nil
    end
    if bb:getType() ~= Blitbuffer.TYPE_BB8 then
        local gray = Blitbuffer.new(bb:getWidth(), bb:getHeight(), Blitbuffer.TYPE_BB8)
        gray:blitFrom(bb, 0, 0, 0, 0, bb:getWidth(), bb:getHeight())
        bb:free()
        bb = gray
    end
    sources[path] = bb
    return bb
end

-- CoverBrowser's cache entry (BookInfoManager:getBookInfo): title, author and Amazon's cover. The cover is a copy
-- the caller owns, as with CoverBrowser's own entries.
function L.bookInfo(path, get_cover)
    local book = virtual[path]
    if not book then return nil end
    local src = coverSource(book.cover)
    local dir, name = path:match("^(.*/)([^/]*)$")
    local info = {
        directory = dir,
        filename = name,
        in_progress = 0,
        cover_fetched = "Y",
        has_meta = "Y",
        title = book.title,
        authors = book.authors ~= "" and book.authors or nil,
        series = book.series,
        series_index = book.series_index,
        has_cover = src and "Y" or nil,
        cover_w = src and src:getWidth() or nil,
        cover_h = src and src:getHeight() or nil,
        cover_sizetag = src and (src:getWidth() .. "x" .. src:getHeight()) or nil,
        quiet_amazon = book,
    }
    if get_cover and src then info.cover_bb = src:copy() end
    return info
end

-- The list's third line: Amazon's progress, then where it opens. Returns the words and how full the progress
-- pill is (nil: no pill, never opened).
function L.statusLine(book)
    local ok, U = pcall(require, "qh_ui")
    local status, pct
    if ok then status, pct = U.amazonStatus(book) end
    local where = "Opens in Amazon's reader"
    if status then return status .. " \u{00B7} " .. where, pct end
    return where, nil
end

-- The marker: a link-out arrow, white on a dark disc with a white ring so it reads on dark and light covers.
local badge_icons = {}
function L.badgeSize(cover_w)
    local d = math.floor(cover_w * (cover_w < 160 and 0.38 or 0.17) + 0.5)
    return math.max(30, math.min(52, d))
end

function L.paintBadge(bb, x, y, d)
    local ok, Q = pcall(require, "quiet_ui")
    if not ok then return end
    local r = math.floor(d / 2)
    Q.fillRound(bb, x, y, d, d, Q.PAPER, r, r, r, r)
    local ring = math.max(2, math.floor(d * 0.08 + 0.5))
    local ir = r - ring
    Q.fillRound(bb, x + ring, y + ring, d - 2 * ring, d - 2 * ring, Q.INK, ir, ir, ir, ir)
    local isz = math.floor(d * 0.5 + 0.5)
    local icon = badge_icons[isz]
    if not icon then
        local IconWidget = require("ui/widget/iconwidget")
        icon = IconWidget:new{ file = iconPath("external-white"), width = isz, height = isz, alpha = true }
        badge_icons[isz] = icon
    end
    icon:paintTo(bb, x + math.floor((d - isz) / 2), y + math.floor((d - isz) / 2))
end

-- Badge on a cover drawn at (x, y, w, h): top-right corner, inside the cover.
function L.paintCoverBadge(bb, x, y, w, h)
    local d = L.badgeSize(w)
    if w < d * 1.6 or h < d * 1.6 then return end
    local inset = math.floor(d * 0.2 + 0.5)
    L.paintBadge(bb, x + w - d - inset, y + inset, d)
end

function L.open(book)
    UIManager:nextTick(function() require("qh_store").open(book) end)
end

function L.hold(book)
    UIManager:nextTick(function()
        local ok, Sheets = pcall(require, "qh_sheets")
        if ok then Sheets.book(book) end
    end)
end

return L
