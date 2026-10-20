--[[
Kindle Store books: the books in Amazon's catalogue on this Kindle that KOReader can't open (KFX, or DRM),
read from Amazon's own content database (/var/local/cc.db, opened read-only). The Home card and its list show
them; tapping one opens it in Amazon's reader (quiet_amazon, when it can) or leaves KOReader for Amazon's home
as the old Store row did.

    local Store = require("qh_store")
    Store.amazonBooks()  -- { book, ... }: books not finished first, newest opened first; then finished ones
    Store.open(book)     -- Amazon's reader for that book, or Amazon's home
    book = {
        asin        = "B0XXXXXXXX",  -- p_cdeKey: the ASIN for store books, Amazon's document key for PDOCs
        cde_key     = same as asin,
        cde_type    = "EBOK" | "PDOC" | ...,
        uuid        = p_uuid (Amazon's id for the catalogue entry),
        path        = p_location ("/mnt/us/documents/Downloads/Items01/....kfx"),
        mime        = p_mimeType,
        title       = shown title (PDOCs lose the " - Author" Amazon keeps from the file name),
        full_title  = p_titles_0_nominal,
        authors     = "Paul Rosolie" (Amazon keeps "Rosolie, Paul"),
        cover       = Amazon's cached cover image (p_thumbnail) or nil,
        pct         = 0..1 from p_percentFinished, or nil when never opened,
        finished    = true when Amazon marked it read (p_readState 1 or 2) or it's at 99.5 %,
        last_opened = unix time (p_lastAccess) or nil,
        added       = unix time it arrived on this Kindle (p_modificationTime, its download) or nil,
        series      = "Sherlock Holmes" and series_index = 5, from a title like "…: Sherlock Holmes, Book 5"
                      (Amazon's own series entries are mostly empty), or nil,
    }
The list is re-read only when cc.db changes. If cc.db can't be read, FALLBACK is used (empty as shipped).
]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local S = {}

S.DB = "/var/local/cc.db"
S.THUMBS = "/mnt/us/system/thumbnails/"

-- Downloaded catalogue items KOReader can't read: KFX (Amazon's current format) or anything DRM-protected.
-- Archived rows are cloud-only copies of the same books. The last column is when the book arrived (its download):
-- `added` is "p_modificationTime" where the catalogue has that column and "NULL" where it doesn't, so a catalogue
-- without it still lists its books.
local function query(added)
    return [[
SELECT p_cdeKey, p_cdeType, p_uuid, p_location, p_mimeType, p_titles_0_nominal, j_credits, p_thumbnail,
       p_percentFinished, p_readState, p_lastAccess, ]] .. added .. [[

FROM Entries
WHERE p_type = 'Entry:Item' AND p_location IS NOT NULL AND p_isArchived = 0
  AND (p_mimeType = 'application/x-kfx-ebook' OR lower(p_location) LIKE '%.kfx' OR p_isDRMProtected = 1)
]]
end
S.query = query

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- "Rosolie, Paul" -> "Paul Rosolie". A name that starts with "The" keeps its order ("The Coach, Giovanni").
function S.personName(display)
    local name = trim(display)
    local last, first = name:match("^([^,]+),%s*([^,]+)$")
    if not last then return name end
    if last:match("^[Tt]he%s") then return trim(last) .. " " .. trim(first) end
    return trim(first) .. " " .. trim(last)
end

-- Author names from j_credits (a JSON list of { name = { display = ... }, kind = "Author" }).
function S.authorsFrom(credits)
    local names = {}
    if type(credits) ~= "string" or credits == "" then return names end
    local ok_j, JSON = pcall(require, "json")
    local ok, list = false, nil
    if ok_j and JSON and JSON.decode then ok, list = pcall(JSON.decode, credits) end
    if ok and type(list) == "table" then
        local any_author = false
        for _, c in ipairs(list) do
            if type(c) == "table" and c.kind == "Author" then any_author = true end
        end
        for _, c in ipairs(list) do
            local display = type(c) == "table" and type(c.name) == "table" and c.name.display
            if display and (c.kind == "Author" or not any_author) then
                names[#names + 1] = S.personName(display)
            end
        end
    else
        for display in credits:gmatch('"display"%s*:%s*"(.-)"') do
            names[#names + 1] = S.personName(display)
        end
    end
    return names
end

-- Personal documents keep the file name Amazon was sent ("Dark Matter - Blake Crouch"): drop the author part.
function S.cleanTitle(title, authors)
    title = trim(title)
    for _, a in ipairs(authors or {}) do
        local suffix = " - " .. a
        if #title > #suffix and title:sub(-#suffix):lower() == suffix:lower() then
            return trim(title:sub(1, #title - #suffix))
        end
    end
    return title
end

-- A book's series and its number, from the few shapes Amazon's titles put them in; nil for any other title.
local SERIES_SHAPES = {
    "^.-:%s*(.-),%s*[Bb]ook%s+(%d+%.?%d*)$",    -- "The Hound of the Baskervilles: Sherlock Holmes, Book 5"
    "^.-%((.-),?%s+[Bb]ook%s+(%d+%.?%d*)%)$",   -- "The Sign of the Four (Sherlock Holmes Book 2)", "(…, Book 2)"
    "^.-%((.-)%s+#(%d+%.?%d*)%)$",              -- "The Sign of the Four (Sherlock Holmes #2)"
    "^.-:%s*(.-)%s+[Bb]ook%s+(%d+%.?%d*)$",     -- "The Sign of the Four: Sherlock Holmes Book 2"
}
function S.seriesFrom(full_title)
    local t = trim(full_title)
    for _, shape in ipairs(SERIES_SHAPES) do
        local series, n = t:match(shape)
        series = series and trim(series)
        if series and series ~= "" then return series, tonumber(n) end
    end
    return nil, nil
end

function S.isFinished(read_state, pct)
    read_state = tonumber(read_state)
    if read_state and read_state >= 1 then return true end
    return pct ~= nil and pct >= 0.995
end

-- Unfinished books first (the ones you'd go to Amazon's reader for), newest opened first; then finished ones.
function S.sortBooks(books)
    table.sort(books, function(a, b)
        if a.finished ~= b.finished then return not a.finished end
        local la, lb = a.last_opened or 0, b.last_opened or 0
        if la ~= lb then return la > lb end
        return (a.title or ""):lower() < (b.title or ""):lower()
    end)
    return books
end

local function fileExists(path)
    return path and lfs.attributes(path, "mode") == "file"
end

-- One book from a query row (positions as in QUERY).
function S.fromRow(row, exists)
    exists = exists or fileExists
    local key, cde_type, uuid, path, mime, full_title, credits, thumb, pct, read_state, last, added =
        row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9], row[10], row[11], row[12]
    if not key or not path then return nil end
    key = tostring(key)
    cde_type = cde_type and tostring(cde_type) or nil
    local names = S.authorsFrom(credits)
    pct = tonumber(pct)
    if pct then pct = math.max(0, math.min(pct / 100, 1)) end
    local cover = thumb and tostring(thumb) or nil
    if not exists(cover) then
        cover = S.THUMBS .. "thumbnail_" .. key .. "_" .. (cde_type or "EBOK") .. "_portrait.jpg"
        if not exists(cover) then cover = nil end
    end
    local title = S.cleanTitle(full_title or "", names)
    local series, series_index = S.seriesFrom(full_title and tostring(full_title) or "")
    return {
        asin = key,
        cde_key = key,
        cde_type = cde_type,
        uuid = uuid and tostring(uuid) or nil,
        path = tostring(path),
        mime = mime and tostring(mime) or nil,
        title = title ~= "" and title or (tostring(path):match("([^/]+)%.[^.]+$") or key),
        full_title = full_title and tostring(full_title) or nil,
        authors = table.concat(names, " & "),
        cover = cover,
        pct = pct,
        finished = S.isFinished(read_state, pct),
        last_opened = tonumber(last),
        added = tonumber(added),
        series = series,
        series_index = series_index,
    }
end

-- Rows (positions as in QUERY) to show when cc.db can't be opened; only books whose files are still there are
-- kept. Empty as shipped: Amazon's catalog is read on each Kindle.
local FALLBACK = {}

function S.fromRows(rows, exists)
    local books, seen = {}, {}
    for _, row in ipairs(rows) do
        local book = S.fromRow(row, exists)
        if book and not seen[book.path] then
            seen[book.path] = true
            books[#books + 1] = book
        end
    end
    return S.sortBooks(books)
end

local function readDb()
    if not fileExists(S.DB) then return nil end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok or not SQ3 then return nil end
    local ok_open, conn = pcall(SQ3.open, S.DB, "ro")
    if not ok_open or not conn then
        logger.warn("quiethome: can't open cc.db:", conn)
        return nil
    end
    local rows = {}
    local ok_q, err = pcall(function()
        local added = "NULL"
        local cols = conn:prepare("PRAGMA table_info(Entries)")
        for col in cols:rows() do
            if tostring(col[2]) == "p_modificationTime" then added = "p_modificationTime" end
        end
        cols:close()
        local stmt = conn:prepare(query(added))
        for row in stmt:rows() do
            local copy = {}
            for i = 1, 12 do copy[i] = row[i] end
            rows[#rows + 1] = copy
        end
        stmt:close()
    end)
    pcall(conn.close, conn)
    if not ok_q then
        logger.warn("quiethome: cc.db query failed:", err)
        return nil
    end
    return rows
end

local cache = { key = nil, books = nil }

function S.amazonBooks()
    local attr = lfs.attributes(S.DB)
    local key = attr and (tostring(attr.modification) .. ":" .. tostring(attr.size)) or "none"
    if cache.books and cache.key == key then return cache.books end
    local rows = readDb()
    local books = S.fromRows(rows or FALLBACK)
    if not rows then
        -- the fallback list only keeps books whose files are still there
        local kept = {}
        for _, b in ipairs(books) do
            if fileExists(b.path) then kept[#kept + 1] = b end
        end
        books = kept
    end
    cache.key, cache.books = key, books
    return books
end

function S.invalidate()
    cache.key, cache.books = nil, nil
end

-- Leave KOReader for Amazon's home, as the old "Kindle Store books" row did (dispatcher action "exit").
-- quiet_amazon's way also closes windows the Exit event leaves up (search results, a sheet), which would keep
-- KOReader running; the dispatcher's is what's left without it.
function S.exitToAmazon()
    local okA, Amazon = pcall(require, "quiet_amazon")
    if okA and type(Amazon) == "table" and Amazon.leaveKOReader and pcall(Amazon.leaveKOReader, 0) then return end
    local ok, Dispatcher = pcall(require, "dispatcher")
    if ok and Dispatcher and Dispatcher.execute then
        local ok2, err = pcall(Dispatcher.execute, Dispatcher, { exit = true })
        if ok2 then return end
        logger.warn("quiethome: exit failed:", err)
    end
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    UIManager:broadcastEvent(Event:new("Exit"))
end

-- Open one book in Amazon's reader when quiet_amazon can; otherwise go to Amazon's home. quiet_amazon.open()
-- leaves for Amazon's home itself when it can't open that book (it returns false then), so it's called once.
function S.open(book)
    local ok, A = pcall(require, "quiet_amazon")
    if ok and type(A) == "table" and A.supported and A.open then
        local ok_s, supported = pcall(A.supported)
        if ok_s and supported then
            local ok_o, err = pcall(A.open, book)
            if ok_o then return end
            logger.warn("quiethome: quiet_amazon failed for", book and book.asin, err)
        end
    end
    S.exitToAmazon()
end

return S
