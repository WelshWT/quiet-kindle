--[[
Quiet library: the Library as a list you can scan, with the cover grid one tap away. Asked for: "default to list
with thumbnails, text titles are easier to scan" (change 017 makes the list the default).

  - one row per book: its cover (rounded like every cover), the title in bold, author and series in grey, then a
    small progress pill with "5% · 12 h 56 min left", "Finished · May" or "On hold · 34%"; nothing for a book
    never opened (no "New" marks, as change 006 asked for the grid)
  - a title too long for one line drops its subtitle ("Frankenstein; or, The Modern Prometheus"), then gets cut with "…"
  - books Amazon's reader finished before KOReader (quietstats' qs_amazon_finished) show as finished
  - separators are a light hairline instead of KOReader's dark rules
  - a grid/list switch on the right of the Library header; it sets CoverBrowser's own display mode, which
    CoverBrowser remembers
  - Amazon's books (the ones only Amazon's reader opens) are in the Library too, sorted with the rest. Asked for: "make
    the kindle store books show in the library with maybe some kind of marker that its from amazon and gonna open
    up in amazons reader". They are virtual entries, nothing is written to documents/: added where KOReader builds
    the Library's item table (and to file search results), described to KOReader and CoverBrowser from Amazon's
    catalogue (qh_library), marked with a link-out badge on the cover and, in the list, "Opens in Amazon's reader".
    A tap opens the book in Amazon's reader; a hold shows where it opens instead of KOReader's file menu; select
    mode leaves them out.
  - a labelled Store button next to search, for Amazon's store and home (qh_sheets.amazon)
  - a "Hide read" toggle left of Sort. Asked for: "add a 'hide read books' toggle in the library". It is
    KOReader's own status filter (show_filter.status: every status but finished), which KOReader remembers; Amazon's
    books follow it; file search still finds read books (KOReader's search never applies the status filter)
  - a Sort button between Hide read and the switch, for five orders: Recent, Date added, Title, Author, Series
    (SORTS below). They are KOReader collates, so the grid and file search follow the order too
  - with SimpleUI's "Library" title off (change 026: "it's already obvious at the bottom"), search is a wide field,
    "Search your library", from the search icon's place to the Store button, which moves up to Hide read
Folders, books not catalogued yet and CoverBrowser's other list modes keep CoverBrowser's own rows. The reading
time left comes from quiet_readtime (the same numbers as Home and Stats); without it the row shows the percent.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local userpatch = require("userpatch")

local LIST_MODE, GRID_MODE = "list_image_meta", "mosaic_image"
local SEPARATOR = Blitbuffer.gray(0.22)
local PILL_TRACK, PILL_FILL = Blitbuffer.gray(0.15), Blitbuffer.gray(0.75)

-- quiet_ui (shapes, faces) is on the module path once plugins are loaded, i.e. by the time anything here runs.
local function getQ()
    local ok, Q = pcall(require, "quiet_ui")
    return ok and type(Q) == "table" and Q or nil
end

local function iconPath(name)
    local DataStorage = require("datastorage")
    local dir = DataStorage.getFullDataDir and DataStorage:getFullDataDir() or DataStorage:getDataDir()
    return dir .. "/icons/quiet/" .. name .. ".svg"
end

-- Amazon's books in the Library (quiethome.koplugin/qh_library), once plugins are loaded. Their made-up paths end
-- in ".kfx", a format KOReader can't open, so only those paths are looked up.
local function amazonLib()
    if G_reader_settings:isTrue("quiet_independent_library") then return nil end
    local ok, L = pcall(require, "qh_library")
    return ok and type(L) == "table" and L or nil
end

local function maybeAmazon(path)
    return type(path) == "string" and path:sub(-4) == ".kfx"
end

local function isAmazon(path)
    if not maybeAmazon(path) then return false end
    local L = amazonLib()
    return L ~= nil and L.book(path) ~= nil
end

-- Amazon's books can never be selected: delete, move, mark finished and the rest would act on a file that isn't
-- there (a status change even writes a sidecar for it into documents/). Every select mode's set of picked files
-- refuses their paths, whichever button fills it (the file manager's, file search's Select all, its hand-over to
-- the file browser).
local SELECTION_GUARD = {
    __newindex = function(t, path, value)
        if value ~= nil and isAmazon(path) then return end
        rawset(t, path, value)
    end,
}
local function guardSelection(t)
    if type(t) ~= "table" or getmetatable(t) ~= nil then return end
    for path in pairs(t) do
        if isAmazon(path) then t[path] = nil end
    end
    setmetatable(t, SELECTION_GUARD)
end

-- In a select mode (the file manager's, or file search's own): taps and holds on Amazon's books do nothing.
local function selecting(menu)
    local ui = menu and menu.ui
    return (ui and ui.selected_files) or (menu and menu._manager and menu._manager.selected_files) or nil
end

-- When a book's status last changed ("2026-05-08"), kept next to KOReader's own per-book cache.
local okBL, BookList = pcall(require, "ui/widget/booklist")
if okBL and BookList and BookList.setBookInfoCache and not BookList._quiet_modified then
    BookList._quiet_modified = true
    local setCache, setProp = BookList.setBookInfoCache, BookList.setBookInfoCacheProperty
    BookList.setBookInfoCache = function(file, doc_settings)
        setCache(file, doc_settings)
        local info = BookList.book_info_cache[file]
        local summary = info and doc_settings and doc_settings:readSetting("summary")
        if summary then info.quiet_modified = summary.modified end
    end
    if setProp then
        BookList.setBookInfoCacheProperty = function(file, prop_name, prop_value)
            setProp(file, prop_name, prop_value)
            local info = BookList.book_info_cache[file]
            if info and prop_name == "status" then info.quiet_modified = os.date("%Y-%m-%d") end
        end
    end
    -- Amazon's books: opened, finished and progress as Amazon's reader recorded them.
    local getBookInfo = BookList.getBookInfo
    BookList.getBookInfo = function(file)
        if maybeAmazon(file) then
            local L = amazonLib()
            local info = L and L.listInfo(file)
            if info then return info end
        end
        return getBookInfo(file)
    end
end

-- Amazon's books join the Library's item table (home folder of the file manager) before KOReader sorts it, and
-- file search results that cover the Library. Select mode leaves them out; taps and holds that reach the file
-- chooser itself (the classic list) open them or show where they open.
local okFC, FileChooser = pcall(require, "ui/widget/filechooser")
local okFS, FileSearcher = pcall(require, "apps/filemanager/filemanagerfilesearcher")
local searching -- the FileSearcher running doSearch()

-- A file search reaches the Library when it searches the Library itself, or a folder above it with subfolders
-- included ("/mnt/us/documents/Book" is not above ".../Books").
local function searchCovers(scope, home, recursive)
    if type(scope) ~= "string" or type(home) ~= "string" then return false end
    scope = scope:gsub("/+$", "")
    if scope == home then return true end
    return recursive and home:sub(1, #scope + 1) == scope .. "/" or false
end

-- KOReader's status filter (its file browser menu's "Filter", our "Hide read" toggle) as FileChooser:show_file()
-- applies it to real files: a book whose status isn't in the filter is left out.
local function filteredOut(path)
    local status = okFC and FileChooser.show_filter and FileChooser.show_filter.status
    return status ~= nil and okBL and not status[BookList.getBookStatus(path)] or false
end
if okFC and FileChooser and FileChooser.genItemTable and not FileChooser._quiet_amazon then
    FileChooser._quiet_amazon = true
    local genItemTable = FileChooser.genItemTable
    FileChooser.genItemTable = function(self, dirs, files, path)
        if type(files) == "table" then
            local L = path and self.name == "filemanager" and amazonLib()
            local home = L and L.homeDir()
            if home and (path:gsub("/+$", "")) == home then
                local ok, items = pcall(L.itemsFor, self, (self:getCollate()))
                if ok then
                    for _, item in ipairs(items) do
                        if not filteredOut(item.path) then files[#files + 1] = item end
                    end
                else
                    logger.warn("quiet library: Amazon books not added:", items)
                end
            elseif not path and searching and okFS then
                L = amazonLib()
                home = L and L.homeDir()
                if searchCovers(FileSearcher.search_path, home, searching.include_subfolders) then
                    local ok, items = pcall(L.searchItems, self, (self:getCollate()), FileSearcher.search_string,
                        searching.case_sensitive)
                    if ok then
                        for _, item in ipairs(items) do files[#files + 1] = item end
                    end
                end
            end
        end
        return genItemTable(self, dirs, files, path)
    end

    local selectAll = FileChooser.selectAllFilesInFolder
    if selectAll then
        FileChooser.selectAllFilesInFolder = function(self, do_select)
            selectAll(self, do_select)
            if not do_select or not (self.ui and self.ui.selected_files) then return end
            local changed = false
            for _, item in ipairs(self.item_table or {}) do
                if item.quiet_amazon then
                    self.ui.selected_files[item.path] = nil
                    item.dim = nil
                    changed = true
                end
            end
            if changed then self:updateItems(1, true) end
        end
    end

    local onMenuSelect, onMenuHold = FileChooser.onMenuSelect, FileChooser.onMenuHold
    FileChooser.onMenuSelect = function(self, item)
        if item and item.quiet_amazon then
            local L = amazonLib()
            if L and not selecting(self) then L.open(item.quiet_amazon) end
            return true
        end
        return onMenuSelect(self, item)
    end
    FileChooser.onMenuHold = function(self, item)
        if item and item.quiet_amazon then
            local L = amazonLib()
            if L and not selecting(self) then L.hold(item.quiet_amazon) end
            return true
        end
        return onMenuHold(self, item)
    end
end
if okFS and FileSearcher and FileSearcher.doSearch and not FileSearcher._quiet_amazon then
    FileSearcher._quiet_amazon = true
    local doSearch = FileSearcher.doSearch
    FileSearcher.doSearch = function(self, ...)
        searching = self
        local ok, err = pcall(doSearch, self, ...)
        searching = nil
        if not ok then error(err, 0) end
    end
    -- File search's own result list (CoverBrowser's classic mode has no item hooks): its tap and hold reject
    -- paths that don't exist, so Amazon's books would do nothing there (review C6 cold read). The results menu is
    -- built with these functions, so `self` is that menu (its _manager is the FileSearcher).
    local onSearchSelect, onSearchHold = FileSearcher.onMenuSelect, FileSearcher.onMenuHold
    if onSearchSelect then
        FileSearcher.onMenuSelect = function(self, item, ...)
            if item and item.quiet_amazon then
                local L = amazonLib()
                if L and not selecting(self) then L.open(item.quiet_amazon) end
                return true
            end
            return onSearchSelect(self, item, ...)
        end
    end
    if onSearchHold then
        FileSearcher.onMenuHold = function(self, item, ...)
            if item and item.quiet_amazon then
                local L = amazonLib()
                if L and not selecting(self) then L.hold(item.quiet_amazon) end
                return true
            end
            return onSearchHold(self, item, ...)
        end
    end
    local setSelectMode = FileSearcher.setSelectMode
    if setSelectMode then
        FileSearcher.setSelectMode = function(self, ...)
            local r = setSelectMode(self, ...)
            guardSelection(self.selected_files)
            return r
        end
    end
end
local okFM, FileManager = pcall(require, "apps/filemanager/filemanager")
if okFM and FileManager and FileManager.onToggleSelectMode and not FileManager._quiet_amazon then
    FileManager._quiet_amazon = true
    local toggle = FileManager.onToggleSelectMode
    FileManager.onToggleSelectMode = function(self, ...)
        local r = toggle(self, ...)
        guardSelection(self.selected_files)
        return r
    end
end

local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
    "November", "December" }

local function monthOf(date)
    local y, m = tostring(date or ""):match("^(%d%d%d%d)%-(%d%d)")
    local name = m and MONTHS[tonumber(m)]
    if not name then return nil end
    if tonumber(y) ~= tonumber(os.date("%Y")) then name = name .. " " .. y end
    return name
end

-- Books Amazon's reader finished before KOReader: file -> latest finish date.
local amazon_finished
local function amazonFinished(file)
    if amazon_finished == nil then
        amazon_finished = {}
        local ok, list = pcall(require, "qs_amazon_finished")
        if ok and type(list) == "table" then
            for _, b in ipairs(list) do
                if b.file and b.finished and (not amazon_finished[b.file] or b.finished > amazon_finished[b.file]) then
                    amazon_finished[b.file] = b.finished
                end
            end
        end
    end
    return amazon_finished[file]
end

local function timeLeft(file)
    local ok, RT = pcall(require, "quiet_readtime")
    if not ok or type(RT) ~= "table" or not RT.forFile or not RT.format then return nil end
    local ok2, t = pcall(RT.forFile, file)
    if not ok2 or type(t) ~= "table" or not t.left_secs or t.left_secs <= 0 then return nil end
    local ok3, s = pcall(RT.format, t.left_secs)
    return ok3 and type(s) == "string" and s or nil
end

-- The status line's words and how full its pill is, or nil for a book never opened.
local function statusFor(file, info)
    local status, pct = info.status, info.percent_finished
    if status == "complete" then
        local month = monthOf(info.quiet_modified)
        return month and ("Finished \u{00B7} " .. month) or "Finished", 1
    end
    -- rounded as Home's card rounds it, so the two agree (RT.percentText); a book just started says 1%
    local percent = pct and pct > 0 and string.format("%d%%", math.max(1, math.floor(pct * 100 + 0.5))) or nil
    if status == "abandoned" then
        return percent and ("On hold \u{00B7} " .. percent) or "On hold", pct or 0
    end
    if percent then
        local left = timeLeft(file)
        return left and (percent .. " \u{00B7} " .. left .. " left") or percent, pct
    end
    local done = amazonFinished(file)
    if done then
        local month = monthOf(done)
        return month and ("Finished \u{00B7} " .. month) or "Finished", 1
    end
    return nil
end

local NO_AUTHOR = { unknown = true, ["n/a"] = true, [""] = true }

-- "Arthur Conan Doyle  ·  Sherlock Holmes #2"
local function authorLine(bookinfo)
    local names = {}
    for name in tostring(bookinfo.authors or ""):gmatch("[^\n]+") do
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if not NO_AUTHOR[name:lower()] then names[#names + 1] = name end
    end
    local line
    if #names == 1 then line = names[1]
    elseif #names == 2 then line = names[1] .. " & " .. names[2]
    elseif #names > 2 then line = names[1] .. " et al." end
    local series = bookinfo.series
    if series and series ~= "" then
        local n = tonumber(bookinfo.series_index)
        if n then series = series .. " #" .. (n == math.floor(n) and string.format("%d", n) or tostring(n)) end
        line = line and (line .. "  \u{00B7}  " .. series) or series
    end
    return line
end

-- Sort orders. Asked for: "a sort by menu on the library page so I can sort by date added, alphabetical, etc".
-- The Kindle's Sort menu has Recent (the last time a book was opened), Title and Author; Kobo adds Date added and
-- Series. Quiet has those five, as KOReader collates (BookList.collates: the file chooser, file search, the cover
-- grid and KOReader's own Sort by menu all read them), registered when this patch loads so a saved one is there
-- the first time KOReader asks for it. They sort by what each book is, not by its file:
--   Recent      last opened first (KOReader's history; Amazon's reader for its own books and for the ones it
--               finished before KOReader); books never opened after them, newest first
--   Date added  newest first: the file's modified date (Amazon's books: their download). Not its change date:
--               KOReader's history touches a book's file each time it's opened (readhistory.lua, for its own
--               "last read date" sort), which sets that one to the time of opening. Kindle Shelf and most copies
--               keep the date the file was made
--   Title       A to Z, a leading "The", "A" or "An" left out, as a library files titles
--   Author      by last name ("Doyle, Arthur Conan"); one author's books in series order, then by title
--   Series      each series A to Z and in its order; then the books in no series, by title
-- Every book gets every key it's sorted by: Amazon's books from their catalogue record, the others from their
-- metadata (CoverBrowser's, without ever opening a book), else their file name. A book that reaches a sort without
-- them (a collection's manual sort) gets them there, so a sort never meets a missing key.
local SORTS = {
    { id = "quiet_recent", label = "Recent", hint = "Last opened first" },
    { id = "quiet_added", label = "Date added", short = "Added", hint = "Newest first" },
    { id = "quiet_title", label = "Title", hint = "A to Z" },
    { id = "quiet_author", label = "Author", hint = "A to Z by last name" },
    { id = "quiet_series", label = "Series", hint = "Each series in order, then other books" },
}

local function lowered(s)
    s = tostring(s or "")
    local ok, util = pcall(require, "util")
    if ok and type(util) == "table" and util.stringLower then
        local ok2, low = pcall(util.stringLower, s)
        if ok2 and type(low) == "string" then return low end
    end
    return s:lower()
end

local ARTICLES = { the = true, a = true, an = true }

-- "The Martian" files under "martian", "'Salem's Lot" under "salem's lot".
local function titleKey(title)
    local t = lowered(title):gsub("^[%s%p]+", ""):gsub("^\226\128[\152-\159]", ""):gsub("^[%s%p]+", "")
    local first, rest = t:match("^(%a+)%s+(%S.*)$")
    if first and ARTICLES[first] then t = rest end
    return t
end

local SUFFIXES = { jr = true, sr = true, ii = true, iii = true, iv = true, phd = true, md = true }
local function suffix(word) return SUFFIXES[lowered((word:gsub("[%.,]", "")))] end

-- The first author, last name first: "Mary Shelley" -> "shelley mary", "Austen, Jane" -> "austen jane",
-- "Martin Luther King, Jr." -> "king martin luther"; nil for no author.
local function authorKey(authors)
    local name = (tostring(authors or ""):match("^%s*([^\n]*)") or ""):gsub("%s+&%s+.*$", "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if NO_AUTHOR[name:lower()] then return nil end
    local last, given = name:match("^([^,]+),%s*(.+)$")
    if last and not suffix(given) then return lowered(last .. " " .. given) end
    local words = {}
    for w in name:gmatch("[^%s,]+") do words[#words + 1] = w end
    while #words > 1 and suffix(words[#words]) do table.remove(words) end
    local surname = table.remove(words)
    if not surname then return nil end
    return lowered(#words > 0 and (surname .. " " .. table.concat(words, " ")) or surname)
end

local function seriesKey(series)
    local s = tostring(series or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and titleKey(s) or nil
end

-- When each book was last opened in KOReader (its history: path -> time), rebuilt when the history changes.
local history = { key = nil, map = {} }
local function historyTime(path)
    local ok, ReadHistory = pcall(require, "readhistory")
    local hist = ok and type(ReadHistory) == "table" and type(ReadHistory.hist) == "table" and ReadHistory.hist or {}
    local top = hist[1]
    local key = #hist .. "|" .. tostring(top and top.time) .. "|" .. tostring(top and top.file)
    if history.key ~= key then
        local map = {}
        for _, e in ipairs(hist) do
            local t = tonumber(e.time)
            if type(e.file) == "string" and t and t > (map[e.file] or 0) then map[e.file] = t end
        end
        history.key, history.map = key, map
    end
    local t = history.map[path]
    if not t then
        -- the history keeps real paths
        local okU, ffiUtil = pcall(require, "ffi/util")
        local real = okU and ffiUtil.realpath and ffiUtil.realpath(path)
        t = real and history.map[real]
    end
    return t
end

local function noonOf(date)
    local y, m, d = tostring(date or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    return y and os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 } or nil
end

local function sortKeys(item, ui, with_props)
    local path = item.path or item.file or ""
    local keys = { name = lowered(item.text or path) }
    local book = item.quiet_amazon
    if book then
        keys.opened = (book.pct ~= nil or book.finished) and book.last_opened or 0
        keys.added = book.added or book.last_opened or 0
        if with_props then
            keys.title = titleKey(book.title)
            keys.author = authorKey((tostring(book.authors or ""):gsub("%s+&%s+", "\n")))
            keys.series, keys.index = seriesKey(book.series), tonumber(book.series_index)
        end
        return keys
    end
    keys.opened = math.max(historyTime(path) or 0, noonOf(amazonFinished(path)) or 0)
    local attr = type(item.attr) == "table" and item.attr.modification and item.attr
    if not attr then
        local lfs = require("libs/libkoreader-lfs")
        attr = lfs.attributes(path) or {}
    end
    keys.added = tonumber(attr.modification) or tonumber(attr.change) or 0
    if with_props then
        local props
        local bi = ui and ui.bookinfo
        if bi and bi.getDocProps then
            local ok, p = pcall(bi.getDocProps, bi, path, nil, true) -- true: never open the book for it
            if ok and type(p) == "table" then props = p end
        end
        props = props or {}
        local title = props.display_title or props.title
        if not title or title == "" then title = path:match("([^/]+)%.[^./]*$") or path:match("[^/]*$") end
        keys.title = titleKey(title)
        keys.author = authorKey(props.authors)
        keys.series, keys.index = seriesKey(props.series), tonumber(props.series_index)
    end
    return keys
end

local function keysOf(item, with_props)
    local k = item.quiet_sort
    if not k or (with_props and k.title == nil) then
        local ok, made = pcall(sortKeys, item, nil, with_props)
        k = ok and made or { name = tostring(item.text or ""), opened = 0, added = 0, title = "" }
        item.quiet_sort = k
    end
    return k
end

local function before(x, y)
    local ok, ffiUtil = pcall(require, "ffi/util")
    if ok and ffiUtil.strcoll then return ffiUtil.strcoll(x, y) end
    return x < y
end

-- nil sorts after any value
local function lastIfNil(x, y)
    if x == nil then return false end
    if y == nil then return true end
    return nil
end

local function byName(a, b) return a.name < b.name end

local function byTitle(a, b)
    if a.title ~= b.title then return before(a.title, b.title) end
    return byName(a, b)
end

local function bySeries(a, b)
    if a.series ~= b.series then
        local r = lastIfNil(a.series, b.series)
        if r ~= nil then return r end
        return before(a.series, b.series)
    end
    if a.index ~= b.index then
        local r = lastIfNil(a.index, b.index)
        if r ~= nil then return r end
        return a.index < b.index
    end
    return byTitle(a, b)
end

local ORDERS = {
    quiet_recent = function(a, b)
        if a.opened ~= b.opened then return a.opened > b.opened end
        if a.added ~= b.added then return a.added > b.added end
        return byName(a, b)
    end,
    quiet_added = function(a, b)
        if a.added ~= b.added then return a.added > b.added end
        return byName(a, b)
    end,
    quiet_title = byTitle,
    quiet_author = function(a, b)
        if a.author ~= b.author then
            local r = lastIfNil(a.author, b.author)
            if r ~= nil then return r end
            return before(a.author, b.author)
        end
        return bySeries(a, b)
    end,
    quiet_series = bySeries,
}

local sorts_ready = false
if okBL and BookList and type(BookList.collates) == "table" then
    for i, s in ipairs(SORTS) do
        local order, with_props = ORDERS[s.id], s.id ~= "quiet_recent" and s.id ~= "quiet_added"
        BookList.collates[s.id] = {
            text = "Quiet: " .. s.label,
            menu_order = 200 + i,
            item_func = function(item, ui)
                local ok, k = pcall(sortKeys, item, ui, with_props)
                item.quiet_sort = ok and k or nil
                if not ok then logger.warn("quiet library: no sort keys for", item.path, k) end
            end,
            init_sort_func = function(cache)
                return function(a, b) return order(keysOf(a, with_props), keysOf(b, with_props)) end, cache
            end,
        }
    end
    sorts_ready = true
end

local function currentSort()
    local id = G_reader_settings:readSetting("collate")
    for _, s in ipairs(SORTS) do
        if s.id == id then return s end
    end
end

local Pill = Widget:extend{ w = 0, h = 0, pct = 0, Q = nil }
function Pill:getSize() return Geom:new{ w = self.w, h = self.h } end
function Pill:paintTo(bb, x, y)
    local Q, r = self.Q, math.floor(self.h / 2)
    Q.fillRound(bb, x, y, self.w, self.h, PILL_TRACK, r, r, r, r)
    local fw = math.floor(self.w * math.max(0, math.min(self.pct or 0, 1)))
    if fw > 0 then Q.fillRound(bb, x, y, math.max(fw, self.h), self.h, PILL_FILL, r, r, r, r) end
end

local Tile = Widget:extend{ w = 0, h = 0, Q = nil }
function Tile:getSize() return Geom:new{ w = self.w, h = self.h } end
function Tile:paintTo(bb, x, y)
    local r = math.max(8, math.floor(math.min(self.w, self.h) * 0.06 + 0.5))
    self.Q.fillRound(bb, x, y, self.w, self.h, self.Q.TRACK, r, r, r, r)
end

-- A cover with the Amazon marker on its top-right corner.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Badged = WidgetContainer:extend{}
function Badged:getSize() return self[1]:getSize() end
function Badged:paintTo(bb, x, y)
    self[1]:paintTo(bb, x, y)
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    local L = amazonLib()
    if L then pcall(L.paintCoverBadge, bb, x, y, sz.w, sz.h) end
end

-- The list's hairlines: one LineWidget per page, inserted between the rows.
local function softenSeparators(menu)
    local group = menu and menu.item_group
    if not group then return end
    for i = 1, #group do
        local w = group[i]
        if type(w) == "table" and w.background and not w._quiet_soft and w.dimen and w.dimen.h and w.dimen.h <= 3 then
            w.background = SEPARATOR
            w._quiet_soft = true
        end
    end
end

-- One book row. Returns true when it replaced the item's content, false to let CoverBrowser draw it.
local function quietRow(item, BookInfoManager)
    local entry = item.entry
    if not entry or not (entry.is_file or entry.file) then return false end
    if not item.do_cover_image or item.do_filename_only then return false end
    local Q = getQ()
    if not Q then return false end
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ImageWidget = require("ui/widget/imagewidget")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local Size = require("ui/size")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local util = require("util")

    local menu, px = item.menu, Q.px
    local dimen = Geom:new{ w = item.width, h = item.height - 2 * item.underline_h }
    local unit_h = dimen.h * 1000 / px(1000) -- row height in 1272-wide units
    local vpad = math.floor(dimen.h * 0.085)
    local box_h = dimen.h - 2 * vpad
    local box_w = math.floor(box_h * 2 / 3 + 0.5)
    local border = Size.border.thin
    local specs = { max_cover_w = box_w - 2 * border, max_cover_h = box_h - 2 * border }
    menu.cover_specs = specs

    local bookinfo = BookInfoManager:getBookInfo(item.filepath, true)
    if not bookinfo then return false end
    local function release()
        if bookinfo.cover_bb then
            bookinfo.cover_bb:free()
            bookinfo.cover_bb = nil
        end
    end
    if bookinfo.unsupported or not bookinfo.cover_fetched then release() return false end
    -- a deleted file (History) or a file picked in select mode: drawn faded; Amazon's books are never picked
    local dim = entry.dim and not entry.quiet_amazon
    local want_cover = bookinfo.has_cover and not bookinfo.ignore_cover
    if want_cover and not menu.no_refresh_covers and BookInfoManager.isCachedCoverInvalid(bookinfo, specs) then
        release()
        return false -- CoverBrowser extracts a bigger cover, then updates this row again
    end

    local has_image = false
    local ok, built = pcall(function()
        local info = menu.getBookInfo(item.filepath)
        local _, filename = util.splitFilePathName(item.filepath)
        local title = (not bookinfo.ignore_meta and bookinfo.title) or filemanagerutil.splitFileNameType(filename)

        local cover
        if want_cover and bookinfo.cover_bb then
            local _, _, scale = BookInfoManager.getCachedCoverSize(bookinfo.cover_w, bookinfo.cover_h,
                specs.max_cover_w, specs.max_cover_h)
            local img = ImageWidget:new{ image = bookinfo.cover_bb, scale_factor = scale }
            img:_render()
            local isz = img:getSize()
            cover = FrameContainer:new{ width = isz.w + 2 * border, height = isz.h + 2 * border,
                margin = 0, padding = 0, bordersize = border, dim = dim, img }
            has_image = true
        else
            release()
            cover = Tile:new{ w = math.floor(box_w * 0.86), h = box_h, Q = Q }
        end
        local amazon = entry.quiet_amazon
        if amazon then cover = Badged:new{ cover } end

        local pad_l, gap, pad_r = px(44), px(30), px(40)
        local text_w = dimen.w - pad_l - box_w - gap - pad_r
        local function size(f, lo, hi) return math.max(lo, math.min(hi, math.floor(unit_h * f + 0.5))) end
        local title_px, author_px, status_px = size(0.215, 28, 38), size(0.18, 24, 31), size(0.165, 22, 28)
        local ink = dim and Q.INK2 or Q.INK

        local twidget = Q.text(title, title_px, { bold = true, color = ink })
        if twidget:getSize().w > text_w then
            twidget:free()
            local main = title:match("^(.-):%s")
            twidget = Q.text(main and #main >= 3 and main or title, title_px,
                { bold = true, color = ink, max_width = text_w })
        end
        local column = VerticalGroup:new{ align = "left", twidget }
        local author = not bookinfo.ignore_meta and authorLine(bookinfo) or nil
        if author then
            column[#column + 1] = VerticalSpan:new{ width = px(2) }
            column[#column + 1] = Q.text(author, author_px, { color = Q.INK2, max_width = text_w })
        end
        local status, pct
        if amazon then
            local L = amazonLib()
            if L then status, pct = L.statusLine(amazon) end
        else
            status, pct = statusFor(item.filepath, info)
        end
        if status then
            local line = HorizontalGroup:new{ align = "center" }
            local room = text_w
            if pct then
                line[#line + 1] = Pill:new{ w = px(190), h = px(10), pct = pct, Q = Q }
                line[#line + 1] = HorizontalSpan:new{ width = px(16) }
                room = room - px(206)
            end
            if amazon then
                -- "… · Opens in Amazon's reader" and the link-out arrow, in the same grey
                local IconWidget = require("ui/widget/iconwidget")
                local isz = px(status_px - 2)
                line[#line + 1] = Q.text(status, status_px, { color = Q.INK2, max_width = room - isz - px(10) })
                line[#line + 1] = HorizontalSpan:new{ width = px(10) }
                line[#line + 1] = IconWidget:new{ file = iconPath("external-ink2"), width = isz, height = isz, alpha = true }
            else
                line[#line + 1] = Q.text(status, status_px, { color = Q.INK2, max_width = room })
            end
            column[#column + 1] = VerticalSpan:new{ width = px(10) }
            column[#column + 1] = line
        end

        local row = LeftContainer:new{
            dimen = dimen:copy(),
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = pad_l },
                CenterContainer:new{ dimen = Geom:new{ w = box_w, h = dimen.h }, cover },
                HorizontalSpan:new{ width = gap },
                column,
            },
        }
        return VerticalGroup:new{ VerticalSpan:new{ width = item.underline_h }, row }
    end)
    if not ok then
        release()
        error(built)
    end
    local widget = built
    local info = menu.getBookInfo(item.filepath)

    item.bookinfo_found = true
    item.been_opened = info and info.been_opened
    item.do_hint_opened = false -- no folded-corner mark on opened books
    item.has_description = false
    if has_image then
        menu._has_cover_images = true
        item._has_cover_image = true
    end
    softenSeparators(menu)
    if item._underline_container[1] then item._underline_container[1]:free() end
    item._underline_container[1] = widget
    return true
end

local list_patched = false
userpatch.registerPatchPluginFunc("coverbrowser", function()
    if list_patched then return end
    local okL, ListMenu = pcall(require, "listmenu")
    local okB, BookInfoManager = pcall(require, "bookinfomanager")
    if not okL or not okB or not ListMenu._updateItemsBuildUI then return end
    local Item = userpatch.getUpValue(ListMenu._updateItemsBuildUI, "ListMenuItem")
    if not Item or not Item.update then return end
    list_patched = true
    local stock_update = Item.update
    Item.update = function(self, ...)
        local ok, handled = pcall(quietRow, self, BookInfoManager)
        if ok and handled then return end
        if not ok then logger.warn("quiet library: row failed, CoverBrowser's row instead:", handled) end
        return stock_update(self, ...)
    end
end)

-- Amazon's books for CoverBrowser: their title, author and cover come from Amazon's catalogue (no extraction for a
-- file that isn't there); in the list and the grid a tap opens the book in Amazon's reader and a hold shows where it
-- opens; the grid draws the marker on their covers (the list draws it in quietRow).
local amazon_patched = false
userpatch.registerPatchPluginFunc("coverbrowser", function()
    if amazon_patched then return end
    local okB, BookInfoManager = pcall(require, "bookinfomanager")
    if not okB or not BookInfoManager.getBookInfo then return end
    amazon_patched = true
    local getInfo = BookInfoManager.getBookInfo
    BookInfoManager.getBookInfo = function(bim, filepath, get_cover, ...)
        if maybeAmazon(filepath) then
            local L = amazonLib()
            local info = L and L.bookInfo(filepath, get_cover)
            if info then return info end
        end
        return getInfo(bim, filepath, get_cover, ...)
    end

    local function hook(Item, badge)
        if not Item or Item._quiet_amazon then return end
        Item._quiet_amazon = true
        local tap, hold = Item.onTapSelect, Item.onHoldSelect
        local function act(self, what)
            local book = self.entry and self.entry.quiet_amazon
            if not book then return false end
            if selecting(self.menu) then return true end
            local L = amazonLib()
            if L then L[what](book) end
            return true
        end
        Item.onTapSelect = function(self, ...)
            if act(self, "open") then return true end
            return tap(self, ...)
        end
        Item.onHoldSelect = function(self, ...)
            if act(self, "hold") then return true end
            return hold(self, ...)
        end
        if badge then
            local paint = Item.paintTo
            Item.paintTo = function(self, bb, x, y)
                paint(self, bb, x, y)
                if self.entry and self.entry.quiet_amazon then
                    local target = self[1] and self[1][1] and self[1][1][1]
                    local d = target and target.dimen
                    local L = amazonLib()
                    if L and d and d.x and d.w and d.w > 0 then pcall(L.paintCoverBadge, bb, d.x, d.y, d.w, d.h) end
                end
            end
        end
    end
    local okL, ListMenu = pcall(require, "listmenu")
    if okL and ListMenu._updateItemsBuildUI then
        hook(userpatch.getUpValue(ListMenu._updateItemsBuildUI, "ListMenuItem"), false)
    end
    local okM, MosaicMenu = pcall(require, "mosaicmenu")
    if okM and MosaicMenu._updateItemsBuildUI then
        hook(userpatch.getUpValue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem"), true)
    end
end)

-- Grid/list switch: a two-segment pill (the same shape as the Stats page's week/year switch), on the right of
-- the Library header where SimpleUI leaves room (its menu and browse buttons are off, change 005).
local ViewSwitch = InputContainer:extend{ fm = nil, h = 0, Q = nil }

local function currentView()
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    local mode = ok and BookInfoManager:getSetting("filemanager_display_mode")
    return type(mode) == "string" and mode:match("^mosaic") and "grid" or "list"
end

function ViewSwitch:init()
    local Q, px = self.Q, self.Q.px
    self.border, self.inset = px(3), px(5)
    self.seg_h = self.h - 2 * (self.border + self.inset)
    self.seg_w = math.floor(self.seg_h * 1.45)
    self.w = 2 * self.seg_w + 2 * (self.border + self.inset)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    local IconWidget = require("ui/widget/iconwidget")
    local isz = math.floor(self.seg_h * 0.72)
    self.icons = {
        grid = IconWidget:new{ file = iconPath("grid"), width = isz, height = isz, alpha = true },
        list = IconWidget:new{ file = iconPath("list"), width = isz, height = isz, alpha = true },
    }
    self.ges_events = {
        TapViewSwitch = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function ViewSwitch:getSize() return Geom:new{ w = self.w, h = self.h } end

function ViewSwitch:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local Q, w, h, b = self.Q, self.w, self.h, self.border
    local r = math.floor(h / 2)
    Q.fillRound(bb, x, y, w, h, Q.LINE, r, r, r, r)
    Q.fillRound(bb, x + b, y + b, w - 2 * b, h - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)
    local current = currentView()
    for i, name in ipairs({ "grid", "list" }) do
        local sx, sy = x + b + self.inset + (i - 1) * self.seg_w, y + b + self.inset
        if name == current then
            local sr = math.floor(self.seg_h / 2)
            Q.fillRound(bb, sx, sy, self.seg_w, self.seg_h, Q.SOFT, sr, sr, sr, sr)
        end
        local icon = self.icons[name]
        local isz = icon:getSize()
        icon:paintTo(bb, sx + math.floor((self.seg_w - isz.w) / 2), sy + math.floor((self.seg_h - isz.h) / 2))
    end
end

function ViewSwitch:onTapViewSwitch(_, ges)
    local want = (ges.pos.x - self.dimen.x) < self.w / 2 and "grid" or "list"
    local browser = self.fm and self.fm.coverbrowser
    if want ~= currentView() and browser and browser.setDisplayMode then
        UIManager:nextTick(function()
            browser:setDisplayMode(want == "grid" and GRID_MODE or LIST_MODE)
            UIManager:setDirty(self.fm, "ui", self.dimen)
        end)
    end
    return true
end

function ViewSwitch:onCloseWidget()
    for _, icon in pairs(self.icons or {}) do icon:free() end
    self.icons = {}
end

-- Store button: the way to Amazon's side (its store, its home) now that Home has no Store card. Cart icon and the
-- word, in an outlined pill like the switch, next to search: both take you somewhere, the switch on the right only
-- changes the view.
local StoreButton = InputContainer:extend{ h = 0, Q = nil }

function StoreButton:init()
    local Q, px = self.Q, self.Q.px
    self.border = px(3)
    local IconWidget = require("ui/widget/iconwidget")
    local isz = math.floor((self.h - 2 * self.border) * 0.62)
    self.icon = IconWidget:new{ file = iconPath("cart"), width = isz, height = isz, alpha = true }
    self.label = Q.text("Store", 29)
    self.pad, self.gap = px(20), px(10)
    self.w = self.pad + isz + self.gap + self.label:getSize().w + self.pad + px(4)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        TapStoreButton = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function StoreButton:getSize() return Geom:new{ w = self.w, h = self.h } end

function StoreButton:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local Q, w, h, b = self.Q, self.w, self.h, self.border
    local r = math.floor(h / 2)
    Q.fillRound(bb, x, y, w, h, Q.LINE, r, r, r, r)
    Q.fillRound(bb, x + b, y + b, w - 2 * b, h - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)
    local isz = self.icon:getSize()
    self.icon:paintTo(bb, x + self.pad, y + math.floor((h - isz.h) / 2))
    local lsz = self.label:getSize()
    self.label:paintTo(bb, x + self.pad + isz.w + self.gap, y + math.floor((h - lsz.h) / 2))
end

function StoreButton:onTapStoreButton()
    UIManager:nextTick(function()
        local ok, Sheets = pcall(require, "qh_sheets")
        if ok then Sheets.amazon() else logger.warn("quiet library: no Amazon sheet:", Sheets) end
    end)
    return true
end

function StoreButton:onCloseWidget()
    if self.icon then self.icon:free() end
    if self.label then self.label:free() end
    self.icon, self.label = nil, nil
end

-- "Hide read": an outlined pill like Store, left of Sort and the grid/list switch. On, it has the switch's soft fill
-- and a check mark, and finished books are left out of the Library (KOReader's status filter, see filteredOut). It
-- is as wide as it is when on, so turning it on doesn't move it.
local ReadFilter = InputContainer:extend{ fm = nil, h = 0, Q = nil }

local function hidingRead()
    local status = okFC and FileChooser.show_filter and FileChooser.show_filter.status
    return status ~= nil and not status.complete
end

function ReadFilter:init()
    local Q, px = self.Q, self.Q.px
    self.border = px(3)
    local IconWidget = require("ui/widget/iconwidget")
    local isz = math.floor((self.h - 2 * self.border) * 0.62)
    self.icon = IconWidget:new{ file = iconPath("check"), width = isz, height = isz, alpha = true }
    self.label = Q.text("Hide read", 29)
    self.pad, self.gap = px(16), px(10)
    self.w = self.pad + isz + self.gap + self.label:getSize().w + self.pad + px(4)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        TapReadFilter = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function ReadFilter:getSize() return Geom:new{ w = self.w, h = self.h } end

function ReadFilter:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local Q, w, h, b = self.Q, self.w, self.h, self.border
    local r = math.floor(h / 2)
    local on = hidingRead()
    Q.fillRound(bb, x, y, w, h, Q.LINE, r, r, r, r)
    Q.fillRound(bb, x + b, y + b, w - 2 * b, h - 2 * b, on and Q.SOFT or Q.PAPER, r - b, r - b, r - b, r - b)
    local lsz = self.label:getSize()
    local lx = x + math.floor((w - lsz.w) / 2)
    if on then
        local isz = self.icon:getSize()
        lx = x + math.floor((w - isz.w - self.gap - lsz.w) / 2)
        self.icon:paintTo(bb, lx, y + math.floor((h - isz.h) / 2))
        lx = lx + isz.w + self.gap
    end
    self.label:paintTo(bb, lx, y + math.floor((h - lsz.h) / 2))
end

function ReadFilter:onTapReadFilter()
    local fm = self.fm
    UIManager:nextTick(function()
        -- FileChooser.show_filter is G_reader_settings' own table, so KOReader saves the choice with its settings
        -- every status but finished (a fresh table: KOReader's own Filter menu edits it in place)
        FileChooser.show_filter.status = not hidingRead() and { new = true, reading = true, abandoned = true } or nil
        if fm and fm.file_chooser then fm.file_chooser:refreshPath() end
        UIManager:setDirty(fm, "ui", self.dimen)
    end)
    return true
end

function ReadFilter:onCloseWidget()
    if self.icon then self.icon:free() end
    if self.label then self.label:free() end
    self.icon, self.label = nil, nil
end

-- Sort: an outlined pill like Hide read, between it and the grid/list switch (all three change what the list
-- shows): the sort icon and the order's word ("Recent", "Added"), as wide as the widest word, so a new order
-- doesn't move it. A tap opens the Sort sheet (qh_sheets.sort); "Sort" while KOReader's own menu has picked one of
-- its orders.
local SortButton = InputContainer:extend{ fm = nil, h = 0, Q = nil }

-- A new order: kept as KOReader's own setting (collate, saved with its settings), read one way only (KOReader's
-- reverse switch would turn "Newest first" into oldest first), and the list back on its first page.
local function applySort(fm, button, id)
    G_reader_settings:saveSetting("collate", id)
    G_reader_settings:delSetting("reverse_collate")
    local fc = fm and fm.file_chooser
    if fc then
        if type(fc.path_items) == "table" and fc.path then fc.path_items[fc.path] = nil end
        fc:refreshPath()
    end
    if button then UIManager:setDirty(fm, "ui", button.dimen) end
end

function SortButton:init()
    local Q, px = self.Q, self.Q.px
    self.border = px(3)
    local IconWidget = require("ui/widget/iconwidget")
    local isz = math.floor((self.h - 2 * self.border) * 0.62)
    self.icon = IconWidget:new{ file = iconPath("sort"), width = isz, height = isz, alpha = true }
    self.labels, self.label_w = { none = Q.text("Sort", 29) }, 0
    for _, s in ipairs(SORTS) do self.labels[s.id] = Q.text(s.short or s.label, 29) end
    for _, label in pairs(self.labels) do self.label_w = math.max(self.label_w, label:getSize().w) end
    self.pad, self.gap = px(16), px(10)
    self.w = self.pad + isz + self.gap + self.label_w + self.pad + px(4)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        TapSortButton = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function SortButton:getSize() return Geom:new{ w = self.w, h = self.h } end

function SortButton:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local Q, w, h, b = self.Q, self.w, self.h, self.border
    local r = math.floor(h / 2)
    Q.fillRound(bb, x, y, w, h, Q.LINE, r, r, r, r)
    Q.fillRound(bb, x + b, y + b, w - 2 * b, h - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)
    local s = currentSort()
    local label = self.labels[s and s.id or "none"]
    local isz, lsz = self.icon:getSize(), label:getSize()
    local lx = x + math.floor((w - isz.w - self.gap - lsz.w) / 2)
    self.icon:paintTo(bb, lx, y + math.floor((h - isz.h) / 2))
    label:paintTo(bb, lx + isz.w + self.gap, y + math.floor((h - lsz.h) / 2))
end

function SortButton:onTapSortButton()
    local fm = self.fm
    UIManager:nextTick(function()
        local ok, Sheets = pcall(require, "qh_sheets")
        if not ok or type(Sheets) ~= "table" or not Sheets.sort then
            logger.warn("quiet library: no Sort sheet:", Sheets)
            return
        end
        local s = currentSort()
        Sheets.sort(SORTS, s and s.id, function(id) applySort(fm, self, id) end)
    end)
    return true
end

function SortButton:onCloseWidget()
    if self.icon then self.icon:free() end
    for _, label in pairs(self.labels or {}) do label:free() end
    self.icon, self.labels = nil, {}
end

-- Search field: with SimpleUI's "Library" title off (change 026: the Library tab already says where you are),
-- search is a wide outlined field from SimpleUI's search button to the Store button, the same file search with a far
-- bigger target than the icon. The hint is grey, as a field's hint is; the word "library" keeps the place named.
local SearchField = InputContainer:extend{ fm = nil, w = 0, h = 0, Q = nil }

function SearchField:init()
    local Q, px = self.Q, self.Q.px
    self.border = px(3)
    local IconWidget = require("ui/widget/iconwidget")
    local isz = math.floor((self.h - 2 * self.border) * 0.62)
    self.icon = IconWidget:new{ file = iconPath("search"), width = isz, height = isz, alpha = true }
    self.pad, self.gap = px(20), px(12)
    -- the longest hint that fits whole: the field narrows as the header gains buttons
    local room = math.max(px(40), self.w - 2 * self.pad - isz - self.gap)
    local hints = { "Search your library", "Search books", "Search" }
    for i, hint in ipairs(hints) do
        local label = Q.text(hint, 29, { color = Q.INK2, max_width = i == #hints and room or nil })
        if i == #hints or label:getSize().w <= room then
            self.label = label
            break
        end
        label:free()
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        TapSearchField = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function SearchField:getSize() return Geom:new{ w = self.w, h = self.h } end

function SearchField:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local Q, w, h, b = self.Q, self.w, self.h, self.border
    local r = math.floor(h / 2)
    Q.fillRound(bb, x, y, w, h, Q.LINE, r, r, r, r)
    Q.fillRound(bb, x + b, y + b, w - 2 * b, h - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)
    local isz, lsz = self.icon:getSize(), self.label:getSize()
    self.icon:paintTo(bb, x + self.pad, y + math.floor((h - isz.h) / 2))
    self.label:paintTo(bb, x + self.pad + isz.w + self.gap, y + math.floor((h - lsz.h) / 2))
end

function SearchField:onTapSearchField()
    local fs = self.fm and self.fm.filesearcher
    if fs and fs.onShowFileSearch then UIManager:nextTick(function() fs:onShowFileSearch() end) end
    return true
end

function SearchField:onCloseWidget()
    if self.icon then self.icon:free() end
    if self.label then self.label:free() end
    self.icon, self.label = nil, nil
end

-- SimpleUI shows the "Library" title unless its title bar item fm_title is off.
local function titleShown()
    local ok, Titlebar = pcall(require, "screens/sui_titlebar")
    if not ok or type(Titlebar) ~= "table" or not Titlebar.isItemVisible then return true end
    return Titlebar.isItemVisible("fm_title")
end

local function inTitleBar(tb, widget)
    for i = 1, #tb do
        if tb[i] == widget then return i end
    end
end

local function addSwitch(fm)
    local tb = fm.title_bar
    if not tb or not fm._titlebar_patched then return end
    local Q = getQ()
    if not Q then return end
    local Screen = require("device").screen
    local search = fm._titlebar_search_btn
    local h = search and search:getSize().h or Q.px(68)
    local y = search and search.overlap_offset and search.overlap_offset[2] or 0
    local gap = Screen:scaleBySize(18)
    if fm.coverbrowser and not (fm._quiet_view_switch and inTitleBar(tb, fm._quiet_view_switch)) then
        local switch = ViewSwitch:new{ fm = fm, h = h, Q = Q }
        switch.overlap_align = nil
        switch.overlap_offset = { Screen:getWidth() - gap - switch.w, y }
        table.insert(tb, switch)
        fm._quiet_view_switch = switch
    end
    if sorts_ready and not (fm._quiet_sort_btn and inTitleBar(tb, fm._quiet_sort_btn)) then
        local sort = SortButton:new{ fm = fm, h = h, Q = Q }
        local right = Screen:getWidth()
        local switch = fm._quiet_view_switch
        if switch and switch.overlap_offset then right = switch.overlap_offset[1] end
        sort.overlap_align = nil
        sort.overlap_offset = { right - Screen:scaleBySize(10) - sort.w, y }
        table.insert(tb, sort)
        fm._quiet_sort_btn = sort
    end
    if okFC and not (fm._quiet_read_filter and inTitleBar(tb, fm._quiet_read_filter)) then
        local filter = ReadFilter:new{ fm = fm, h = h, Q = Q }
        local right = Screen:getWidth()
        local switch = fm._quiet_sort_btn or fm._quiet_view_switch
        if switch and switch.overlap_offset then right = switch.overlap_offset[1] end
        -- close to Sort and the switch (all three change what the list shows), clear of the "Library" title
        filter.overlap_align = nil
        filter.overlap_offset = { right - Screen:scaleBySize(10) - filter.w, y }
        table.insert(tb, filter)
        fm._quiet_read_filter = filter
    end
    if not G_reader_settings:isTrue("quiet_independent_library") and not (fm._quiet_store_btn and inTitleBar(tb, fm._quiet_store_btn)) then
        local store = StoreButton:new{ h = h, Q = Q }
        local x = gap
        if search and search.overlap_offset then x = search.overlap_offset[1] + search:getSize().w + gap end
        -- no title: the search field takes the room and Store moves up to Hide read
        local wide = search and search.overlap_offset and not titleShown()
        if wide then
            local filter = fm._quiet_read_filter
            local right = filter and filter.overlap_offset and filter.overlap_offset[1] or Screen:getWidth()
            x = right - gap - store.w
        end
        store.overlap_align = nil
        store.overlap_offset = { x, y }
        table.insert(tb, store)
        fm._quiet_store_btn = store
        if wide and not (fm._quiet_search_field and inTitleBar(tb, fm._quiet_search_field)) then
            local sx = search.overlap_offset[1]
            local field = SearchField:new{ fm = fm, h = h, Q = Q, w = x - gap - sx }
            field.overlap_align = nil
            field.overlap_offset = { sx, y }
            -- SimpleUI's icon stays underneath; without its callback a tap passes on to the field, no icon flash
            search.callback = nil
            table.insert(tb, field)
            fm._quiet_search_field = field
        end
    end
end

local function removeSwitch(fm)
    local tb = fm.title_bar
    for _, key in ipairs({ "_quiet_view_switch", "_quiet_sort_btn", "_quiet_store_btn", "_quiet_read_filter",
            "_quiet_search_field" }) do
        local widget = fm[key]
        if widget then
            local i = tb and inTitleBar(tb, widget)
            if i then table.remove(tb, i) end
            fm[key] = nil
            widget:onCloseWidget()
        end
    end
end

local switch_patched = false
userpatch.registerPatchPluginFunc("simpleui", function()
    if switch_patched then return end
    local ok, Titlebar = pcall(require, "screens/sui_titlebar")
    if not ok or type(Titlebar) ~= "table" or not Titlebar.apply or not Titlebar.restore then return end
    switch_patched = true
    local apply, restore = Titlebar.apply, Titlebar.restore
    Titlebar.apply = function(fm, ...)
        local r = apply(fm, ...)
        local ok2, err = pcall(addSwitch, fm)
        if not ok2 then logger.warn("quiet library: no grid/list switch or Store button:", err) end
        return r
    end
    Titlebar.restore = function(fm, ...)
        pcall(removeSwitch, fm)
        return restore(fm, ...)
    end
end)
