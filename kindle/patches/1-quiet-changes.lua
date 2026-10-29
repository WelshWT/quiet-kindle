--[[
Quiet: apply new change files before KOReader reads any settings.

Each file in settings/quiet/changes/ (sorted by name) is applied once. A change is a Lua file returning:

    {
        note     = "what this change is for",
        reader   = { key = value, ["a.b"] = value, gone = "__delete__" }, -- settings.reader.lua
        simpleui = { ... },                                              -- settings/simpleui/sui_settings.lua
        gestures = { ["gesture_reader.tap_top_left_corner"] = {} },      -- settings/gestures.lua
        ["file:defaults.custom.lua"] = { ... },                          -- any other settings-style file
        ["sql:settings/statistics.sqlite3"] = { "DELETE FROM …;", ... },  -- raw SQL, whole db backed up first
        books    = { strip = { "copt_font_size", ... } },                -- drop per-book overrides
        undo     = "007-some-change",                                    -- or: put back what that change replaced
    }

Dotted keys reach into nested tables. Whatever a change replaces is saved to settings/quiet/undo/<id>.lua,
so a later `undo` change can put it back. Runs as an "early" user patch: settings files are rewritten on
disk before KOReader and its plugins open them, so nothing in memory can overwrite the change afterwards.

Safe to interrupt (review C1-2/3/4, 19 Oct): a change first records everything it is about to replace (settings
values, and a consistent copy of each database it runs SQL on, taken with sqlite3's .backup so pages still in the
WAL are included), then changes things, then is marked applied. A change that fails or is cut short stays pending
and runs again at the next start, and the record of its first attempt is kept, so undo still puts back what was
there before it began. sqlite3 runs with -bail and its exit status is checked; the SQL of one change runs as one
transaction (so no VACUUM in a change), and a last ".print" proves sqlite3 read the whole statement file. Every Lua
file this patch writes (settings files, book sidecars, the undo record, the registry) is written whole to a temp file
beside it, synced, read back and compared whole, and only then renamed over it. LuaSettings:flush() would write in
place, ignore a failed write, and refresh its .old copy only for a file at least a minute old: a short write there
could leave a stale copy or an empty table behind, which a check of the changed keys alone would pass (review C1-15,
C1-29). A file is read as KOReader will read it: the file itself, or its .old copy when only that is left (KOReader
renames a file to .old just before writing it again, so a crash in between leaves only the .old: review C1-F1). One
that is there but can't be read stops the change instead of being replaced by LuaSettings' quiet fallback (the .old
or an empty table); an unreadable book sidecar is left out of a strip and logged. Undoing an undo works for
every kind of section (review C1-14..17). A failure stops the queue (logged in settings/quiet/log.txt) until it's
fixed.
]]

local DataStorage = require("datastorage")
local dump = require("dump")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local DELETE, ABSENT = "__delete__", "__absent__"
local data_dir = DataStorage:getDataDir()
local settings_dir = DataStorage:getSettingsDir()
local quiet_dir = settings_dir .. "/quiet"
local changes_dir = quiet_dir .. "/changes"
local undo_dir = quiet_dir .. "/undo"
local docs_dir = os.getenv("QUIET_DOCS_DIR") or "/mnt/us/documents" -- tests point it elsewhere

local files = {
    reader = data_dir .. "/settings.reader.lua",
    simpleui = settings_dir .. "/simpleui/sui_settings.lua",
    gestures = settings_dir .. "/gestures.lua",
}

local function log(...)
    local parts = { os.date("%Y-%m-%d %H:%M:%S") }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, " ")
    logger.info("quiet:", line)
    local f = io.open(quiet_dir .. "/log.txt", "a")
    if f then f:write(line, "\n") f:close() end
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end

local function same(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-9 end
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not same(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function split(path)
    local parts = {}
    for part in path:gmatch("[^%.]+") do parts[#parts + 1] = tonumber(part) or part end
    return parts
end

local function getPath(t, path)
    local cur = t
    for _, part in ipairs(split(path)) do
        if type(cur) ~= "table" then return nil end
        cur = cur[part]
    end
    return cur
end

local function setPath(t, path, value)
    local parts = split(path)
    local cur = t
    for i = 1, #parts - 1 do
        if type(cur[parts[i]]) ~= "table" then cur[parts[i]] = {} end
        cur = cur[parts[i]]
    end
    if value == DELETE or value == ABSENT then
        cur[parts[#parts]] = nil
    else
        cur[parts[#parts]] = copy(value)
    end
end

-- Write a small file in one step (temp file, then rename), so nobody reads half of it and a link planted at the
-- name is replaced rather than followed.
local function publish(path, text)
    local tmp = os.tmpname()
    local f = io.open(tmp, "w")
    local ok = f and f:write(text, "\n")
    ok = f and f:close() and ok
    if not (ok and os.rename(tmp, path)) then os.remove(tmp) end
end

-- Lua data files (settings, sidecars, undo records, the registry): read strictly (nil when there is none, an error
-- when it is there but unreadable), replaced in one step.
local function loadLua(path)
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok, t = pcall(dofile, path)
    if not ok or type(t) ~= "table" then error("can't read " .. path .. ": " .. tostring(t)) end
    return t
end

-- The whole table to a temp file beside the file, synced, read back and compared whole, then renamed over the file;
-- anything short of that leaves the file as it was. (The syncs are best effort, as in KOReader's own writes.)
local function saveLua(path, data)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    local ok = f and f:write("-- ", path, "\nreturn ", dump(data, nil, true), "\n")
    if ok then pcall(ffiutil.fsyncOpenedFile, f) end
    ok = f and f:close() and ok
    local readable, back = false, nil
    if ok then readable, back = pcall(loadLua, tmp) end
    if not (readable and same(back, data) and os.rename(tmp, path)) then
        os.remove(tmp)
        error("could not write " .. path)
    end
    pcall(ffiutil.fsyncDirectory, path)
end

-- A settings file or book sidecar as KOReader will read it: the file, or its .old copy when only that is there; nil
-- when there is neither, an error when the one that counts can't be read.
local function loadSettings(path)
    if lfs.attributes(path, "mode") == "file" then return loadLua(path) end
    return loadLua(path .. ".old")
end

local function settingsExist(path)
    return lfs.attributes(path, "mode") == "file" or lfs.attributes(path .. ".old", "mode") == "file"
end

-- KOReader reads a book's settings from whichever of several places holds the newest copy (DocSettings:open: the
-- book's own .sdr folder, the central docsettings folder, the hash folder, the legacy history folder, ...). Writing
-- the copy in the book's .sdr folder makes it the newest, so that is only safe for a book whose settings live
-- nowhere else: this names the first other copy found, or nil (review C1-F3).
local function elsewhere(sidecar)
    local dir, name, ext = sidecar:match("^(.*)/([^/]+)%.sdr/metadata%.(.+)%.lua$")
    if not dir then return nil end
    dir = ffiutil.realpath(dir) or dir -- as KOReader names the book (a file: section reaches it through "..")
    local doc = dir .. "/" .. name .. "." .. ext
    local file = "metadata." .. ext .. ".lua"
    local central = data_dir .. "/docsettings" .. dir .. "/" .. name .. ".sdr/" .. file
    local others = { dir .. "/" .. name .. ".sdr/" .. name .. "." .. ext .. ".lua", central, central .. ".old",
        doc .. ".kpdfview.lua" }
    if lfs.attributes(data_dir .. "/history", "mode") == "directory" then
        local h = data_dir .. "/history/[" .. doc:gsub("(.*/)([^/]+)", "%1] %2"):gsub("/", "#") .. ".lua"
        others[#others + 1] = h
        others[#others + 1] = h .. ".old"
    end
    if lfs.attributes(data_dir .. "/hashdocsettings", "mode") == "directory" then
        local ok, hash = pcall(function() return require("util").partialMD5(doc) end)
        if not ok then return data_dir .. "/hashdocsettings (the book can't be hashed)" end
        if hash then
            local h = data_dir .. "/hashdocsettings/" .. hash:sub(1, 2) .. "/" .. hash .. ".sdr/" .. file
            others[#others + 1] = h
            others[#others + 1] = h .. ".old"
        end
    end
    for _, other in ipairs(others) do
        if lfs.attributes(other, "mode") == "file" then return other end
    end
end

-- sqlite3 with the statements in a file (no shell quoting), stopping at the first error; raises when it fails.
local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local DONE = "quiet-sqlite-done"

local function sqlite(db, statements)
    local input, output = os.tmpname(), os.tmpname()
    local f = io.open(input, "w")
    local ok = f and f:write(table.concat(statements, "\n"), "\n.print ", DONE, "\n")
    ok = f and f:close() and ok
    local rc = ok and os.execute(string.format("sqlite3 -bail %s < %s > %s 2>&1",
        shellQuote(db), shellQuote(input), shellQuote(output)))
    local o = io.open(output, "r")
    local text = o and o:read("*a") or ""
    if o then o:close() end
    os.remove(input)
    os.remove(output)
    if not ok then error("could not write the statements for " .. db) end
    -- the last line proves sqlite3 got to the end of the file (a cut-short file can still exit 0)
    local body, last = text:match("^(.-)([^\n]*)\n?$")
    if (rc ~= 0 and rc ~= true) or last ~= DONE then
        error(string.format("sqlite3 failed on %s: %s", db, (text:gsub("%s+$", ""))))
    end
    return body
end

local function sqlQuote(s)
    return "'" .. tostring(s):gsub("'", "''") .. "'"
end

-- Key/value tables in SQLite settings databases, e.g. section
-- ["sqlite:settings/bookinfo_cache.sqlite3:config"] = { filemanager_display_mode = "mosaic_image" }
local function readSqlite(db, tbl, values)
    local before = {}
    for key in pairs(values) do
        local old = sqlite(db, { string.format("SELECT value FROM %s WHERE key=%s;", tbl, sqlQuote(key)) })
        old = old:gsub("%s+$", "")
        before[key] = old == "" and ABSENT or (tonumber(old) or old)
    end
    return before
end

local function writeSqlite(db, tbl, values)
    local sql = { "BEGIN;" }
    for key, value in pairs(values) do
        if value == DELETE or value == ABSENT then
            sql[#sql + 1] = string.format("DELETE FROM %s WHERE key=%s;", tbl, sqlQuote(key))
        else
            sql[#sql + 1] = string.format("INSERT OR REPLACE INTO %s(key, value) VALUES(%s, %s);",
                tbl, sqlQuote(key), sqlQuote(value))
        end
    end
    sql[#sql + 1] = "COMMIT;"
    sqlite(db, sql)
end

-- Raw SQL against a database file. Before it runs, a consistent copy of the whole database goes to
-- undo/<id>.<name> (sqlite3's .backup: WAL pages included); undoing the change restores that copy (.restore).
local function backupName(id, rel)
    return undo_dir .. "/" .. id .. "." .. rel:gsub("[/%s]", "_")
end

local function runSql(db, statements)
    local sql = { "BEGIN;" }
    for _, s in ipairs(statements) do sql[#sql + 1] = s end
    sql[#sql + 1] = "COMMIT;"
    sqlite(db, sql)
end

local function fileFor(section)
    if files[section] then return files[section] end
    local rel = section:match("^file:(.+)$")
    if rel then return data_dir .. "/" .. rel end
end

-- What a settings section would replace (nothing is changed).
local function readSection(path, values)
    local data = loadSettings(path) or {}
    local before = {}
    for key in pairs(values) do
        local old = getPath(data, key)
        before[key] = old == nil and ABSENT or copy(old)
    end
    return before
end

-- Set the values in the file as it is on disk, and write it whole (saveLua). A book's sidecar is written only
-- when its settings live nowhere else.
local function writeSection(path, values)
    local other = elsewhere(path)
    if other then error(path .. " not written: this book's settings are also in " .. other) end
    local data = loadSettings(path) or {}
    for key, value in pairs(values) do setPath(data, key, value) end
    saveLua(path, data)
end

local function sidecars()
    local found = {}
    local function walk(dir, depth)
        if depth > 3 or lfs.attributes(dir, "mode") ~= "directory" then return end
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." then
                local p = dir .. "/" .. entry
                if entry:match("%.sdr$") then
                    for f in lfs.dir(p) do
                        if f:match("^metadata%..+%.lua$") then
                            found[#found + 1] = p .. "/" .. f
                        elseif f:match("^metadata%..+%.lua%.old$") and lfs.attributes(p .. "/" .. f:sub(1, -5), "mode") ~= "file" then
                            found[#found + 1] = p .. "/" .. f:sub(1, -5) -- only the .old is left: KOReader reads that
                        end
                    end
                elseif lfs.attributes(p, "mode") == "directory" then
                    walk(p, depth + 1)
                end
            end
        end
    end
    walk(docs_dir, 0)
    return found
end

-- Per-book values a strip would remove: { [sidecar] = { key = value } }. A sidecar that can't be read, or whose
-- book keeps settings somewhere else too, is left alone (and logged).
local function readBooks(keys)
    local before = {}
    for _, path in ipairs(sidecars()) do
        local other = elsewhere(path)
        local readable, data = true, {}
        if other then
            log("left out", path, "- this book's settings are also in", other)
        else
            readable, data = pcall(loadSettings, path)
        end
        if not readable or not data then
            log("left out an unreadable sidecar:", path)
            data = {}
        end
        for _, key in ipairs(keys) do
            if data[key] ~= nil then
                before[path] = before[path] or {}
                before[path][key] = copy(data[key])
            end
        end
    end
    return before
end

local function writeBooks(paths, keys)
    for path in pairs(paths) do
        local other = elsewhere(path) -- a copy elsewhere since the values were read: leave the book alone
        if other then log("left out", path, "- this book's settings are also in", other) end
        local data = not other and loadSettings(path)
        if data then -- a book removed since: nothing to strip
            for _, key in ipairs(keys) do data[key] = nil end
            saveLua(path, data)
        end
    end
end

-- What restoring saved per-book values would replace: { [sidecar] = { key = value or "__absent__" } }.
local function readBookValues(saved)
    local before = {}
    for path, values in pairs(saved) do
        if settingsExist(path) then
            local data = loadSettings(path)
            before[path] = {}
            for key in pairs(values) do
                if data[key] == nil then before[path][key] = ABSENT else before[path][key] = copy(data[key]) end
            end
        end
    end
    return before
end

local function restoreBooks(saved)
    for path, values in pairs(saved) do
        local other = settingsExist(path) and elsewhere(path)
        if other then
            log("left out", path, "- this book's settings are also in", other)
        elseif settingsExist(path) then
            writeSection(path, values)
        end
    end
end

-- The record of what a change replaced. An earlier attempt that was cut short recorded what was there before
-- the change began; that wins over anything read now (by then, part of the change may already be in place).
local function remember(record, section, values)
    local old = record[section]
    if type(old) ~= "table" or type(values) ~= "table" then
        if old == nil then record[section] = values end
        return
    end
    for k, v in pairs(values) do
        if old[k] == nil then
            old[k] = v
        elseif section == "books" and type(old[k]) == "table" and type(v) == "table" then
            for kk, vv in pairs(v) do
                if old[k][kk] == nil then old[k][kk] = vv end
            end
        end
    end
end

-- A consistent copy of a database before this change touches it (kept from an earlier attempt if there is one).
local function backupOnce(record, section, id, rel, path)
    local kept = record[section]
    if kept and kept.backup and lfs.attributes(kept.backup, "mode") == "file" then return end
    local backup = backupName(id, rel)
    sqlite(path, { ".backup " .. sqlQuote(backup) })
    record[section] = { backup = backup, path = path }
end

local function applyChange(id, change)
    local journal_path = undo_dir .. "/" .. id .. ".lua"
    local record = loadLua(journal_path) or {}
    local steps = {}

    -- 1. Read (and back up) what this change will replace; change nothing yet.
    if change.undo then
        local saved = loadLua(undo_dir .. "/" .. change.undo .. ".lua")
        if not saved then error("nothing recorded for " .. change.undo) end
        for section, values in pairs(saved) do
            local db, tbl = section:match("^sqlite:(.+):([%w_]+)$")
            local sql_rel = section:match("^sql:(.+)$")
            if section == "books" then
                remember(record, "books", readBookValues(values))
                steps[#steps + 1] = function() restoreBooks(values) end
            elseif sql_rel then
                if values.backup and values.path then
                    -- so that this undo can be undone too
                    backupOnce(record, section, id, sql_rel, values.path)
                    steps[#steps + 1] = function() sqlite(values.path, { ".restore " .. sqlQuote(values.backup) }) end
                end
            elseif db then
                remember(record, section, readSqlite(data_dir .. "/" .. db, tbl, values))
                steps[#steps + 1] = function() writeSqlite(data_dir .. "/" .. db, tbl, values) end
            else
                local path = fileFor(section)
                if path then
                    remember(record, section, readSection(path, values))
                    steps[#steps + 1] = function() writeSection(path, values) end
                end
            end
        end
    end
    for section, values in pairs(change) do
        local db, tbl, sql_rel
        if type(section) == "string" then
            db, tbl = section:match("^sqlite:(.+):([%w_]+)$")
            sql_rel = section:match("^sql:(.+)$")
        end
        if section == "books" then
            if values.strip then
                remember(record, "books", readBooks(values.strip))
                steps[#steps + 1] = function() writeBooks(record.books or {}, values.strip) end
            end
        elseif sql_rel then
            local path = data_dir .. "/" .. sql_rel
            if lfs.attributes(path, "mode") ~= "file" then error("no database " .. path) end
            backupOnce(record, section, id, sql_rel, path)
            steps[#steps + 1] = function() runSql(path, values) end
        elseif db then
            remember(record, section, readSqlite(data_dir .. "/" .. db, tbl, values))
            steps[#steps + 1] = function() writeSqlite(data_dir .. "/" .. db, tbl, values) end
        elseif section ~= "note" and section ~= "undo" then
            local path = fileFor(section)
            if path and type(values) == "table" then
                remember(record, section, readSection(path, values))
                steps[#steps + 1] = function() writeSection(path, values) end
            else
                log("skipped unknown section", section, "in", id)
            end
        end
    end

    -- 2. Keep that record before anything changes (replaced in one step, and read back).
    saveLua(journal_path, record)

    -- 3. Make the change.
    for _, step in ipairs(steps) do step() end
    if change.undo then log("undid", change.undo) end
end

local function run()
    for _, dir in ipairs({ quiet_dir, changes_dir, undo_dir }) do
        if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    end
    local registry_path = quiet_dir .. "/applied.lua"
    local registry = loadLua(registry_path) or {}
    local applied = registry.applied or {}
    local pending = {}
    for entry in lfs.dir(changes_dir) do
        -- macOS creates AppleDouble ._ files on the Kindle's FAT volume.
        -- Hidden metadata is not an executable settings change.
        local id = entry:match("^([^.].*)%.lua$")
        if id and not applied[id] then pending[#pending + 1] = id end
    end
    table.sort(pending)
    local done = {}
    for _, id in ipairs(pending) do
        local ok, change = pcall(dofile, changes_dir .. "/" .. id .. ".lua")
        if not ok or type(change) ~= "table" then
            log("could not read", id, change)
            break
        end
        local ok2, err = pcall(applyChange, id, change)
        if not ok2 then
            log("failed", id, err)
            break
        end
        applied[id] = os.time()
        registry.applied = applied
        local ok3, err3 = pcall(saveLua, registry_path, registry)
        if not ok3 then
            log("failed", id, "applied, but could not record it (it runs again at the next start):", err3)
            break
        end
        done[#done + 1] = id
        log("applied", id, change.note or "")
    end
    publish("/tmp/quiet-applied", table.concat(done, " "))
end

local ok, err = pcall(run)
if not ok then log("error", err) end
