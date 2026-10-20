--[[
Numbers for the Stats page: KOReader's reading statistics (settings/statistics.sqlite3), its reading history,
and the books Amazon's reader recorded as finished before KOReader (qs_amazon_finished.lua).

A reading day is any day with at least one page turned. A streak forgives one quiet day per week (Mon-Sun):
missing a single day doesn't slow habit-building (Lally et al. 2010), and a streak that can be repaired doesn't
make people give up the way a broken one does (Silverman & Barasch 2023).
]]

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local D = {}

local DB = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
local HEAT_WEEKS = 26
local DEFAULT_SECS_PER_PAGE = 75 -- ~250 words a page at 200 words a minute

-- Dates are handled at local noon, so adding days never trips over a daylight-saving change.
local function noonOf(t)
    local d = os.date("*t", t)
    return os.time{ year = d.year, month = d.month, day = d.day, hour = 12 }
end
local function addDays(t, n)
    local d = os.date("*t", t)
    return os.time{ year = d.year, month = d.month, day = d.day + n, hour = 12 }
end
local function key(t) return os.date("%Y-%m-%d", t) end
local function mondayOf(t) return addDays(t, -((os.date("*t", t).wday + 5) % 7)) end
local function parse(k)
    local y, m, d = k:match("^(%d+)-(%d+)-(%d+)")
    return os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
end
D.addDays, D.key, D.mondayOf, D.parse = addDays, key, mondayOf, parse

local function query(sql)
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq or lfs.attributes(DB, "mode") ~= "file" then return nil end
    local ok, conn = pcall(SQ3.open, DB)
    if not ok or not conn then return nil end
    local ok2, res = pcall(conn.exec, conn, sql)
    conn:close()
    if not ok2 then
        logger.warn("quietstats: query failed:", res)
        return nil
    end
    return res
end

-- Seconds read per local day, all of history: the same honest count as Home and the reader's footer
-- (quiet_readtime.lua: idling on a page doesn't count), or KOReader's raw sums if that isn't there.
local function secondsByDay()
    local ok_rt, RT = pcall(require, "quiet_readtime")
    if ok_rt then
        local ok, by_day, order = pcall(RT.secondsByDay)
        if ok and by_day then return by_day, order end
        logger.warn("quietstats: honest reading time unavailable:", by_day)
    end
    local res = query([[
        SELECT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS d, sum(duration) AS secs
        FROM page_stat_data GROUP BY d ORDER BY d;]])
    local by_day, order = {}, {}
    if res and res[1] then
        for i = 1, #res[1] do
            local d = res[1][i]
            by_day[d] = tonumber(res[2][i]) or 0
            order[#order + 1] = d
        end
    end
    return by_day, order
end

-- The streak that ends on day t, walking back: reading days count, one quiet day per week (Mon-Sun) is forgiven,
-- a second one in the same week ends it. Returns the number of reading days and a mark per day: "read" or "rest"
-- (a forgiven quiet day).
local function streakEndingAt(read, t)
    local marks, used = {}, {}
    local count = 0
    for _ = 1, 3660 do
        local k = key(t)
        if read[k] then
            count = count + 1
            marks[k] = "read"
        else
            local wk = key(mondayOf(t))
            if used[wk] then break end
            used[wk] = true
            marks[k] = "rest"
        end
        t = addDays(t, -1)
    end
    -- quiet days older than the streak's first reading day aren't part of it
    local oldest
    for k, m in pairs(marks) do
        if m == "read" and (not oldest or k < oldest) then oldest = k end
    end
    for k, m in pairs(marks) do
        if m == "rest" and (not oldest or k < oldest) then marks[k] = nil end
    end
    return count, marks
end

-- Current streak: today doesn't break anything until it's over.
local function currentStreak(read, today)
    local t = today
    if not read[key(t)] then t = addDays(t, -1) end
    return streakEndingAt(read, t)
end

-- Best streak: the longest streak ending on any reading day. Only days after which the next day is quiet need
-- trying (a streak ending a day later on a reading day is one longer), so this stays quick on a long history.
local function bestStreak(read, order, today)
    local best = 0
    for _, k in ipairs(order) do
        if read[k] then
            local t = parse(k)
            if t <= today and not read[key(addDays(t, 1))] then
                local n = streakEndingAt(read, t)
                if n > best then best = n end
            end
        end
    end
    return best
end
D._bestStreak, D._currentStreak = bestStreak, currentStreak -- for tests

local function weeksInRow(read, today)
    local function hasRead(monday)
        for i = 0, 6 do
            if read[key(addDays(monday, i))] then return true end
        end
    end
    local wk, n = mondayOf(today), 0
    if not hasRead(wk) then wk = addDays(wk, -7) end
    for _ = 1, 520 do
        if not hasRead(wk) then break end
        n = n + 1
        wk = addDays(wk, -7)
    end
    return n
end

-- The book being read: the most recent one in the history that isn't marked finished.
local function currentBook()
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok then return nil end
    for _, e in ipairs(ReadHistory.hist or {}) do
        -- KOReader's own help pages aren't a book
        if e.file and not e.file:find("/koreader/help/", 1, true) and lfs.attributes(e.file, "mode") == "file"
                and DocSettings:hasSidecarFile(e.file) then
            local ds = DocSettings:open(e.file)
            local summary = ds:readSetting("summary") or {}
            if summary.status ~= "complete" then
                local props = ds:readSetting("doc_props") or {}
                local title = props.title
                if not title or title == "" then
                    title = e.file:match("([^/]+)%.[^.]+$") or e.file
                end
                return {
                    file = e.file,
                    title = title,
                    pct = tonumber(ds:readSetting("percent_finished")) or 0,
                    pages = tonumber(ds:readSetting("doc_pages")) or 0,
                    md5 = ds:readSetting("partial_md5_checksum"),
                }
            end
        end
    end
end

-- Seconds a page takes: this book's own pace once there's enough of it, else the last month's across books.
local function secsPerPage(md5)
    local function avg(where)
        local res = query("SELECT sum(duration), count(DISTINCT id_book || ':' || page) FROM page_stat_data WHERE " .. where .. ";")
        local secs = res and tonumber(res[1][1]) or 0
        local pages = res and tonumber(res[2][1]) or 0
        if pages >= 20 then return secs / pages end
    end
    local per
    if md5 then
        per = avg(string.format("id_book = (SELECT id FROM book WHERE md5 = '%s' LIMIT 1)", tostring(md5):gsub("'", "")))
    end
    per = per or avg("start_time >= " .. (os.time() - 30 * 86400)) or DEFAULT_SECS_PER_PAGE
    return math.max(20, math.min(per, 240))
end

-- Finished books for a year: Amazon's records plus books KOReader has marked finished.
local function finishedBooks(year)
    local books, seen = {}, {}
    local function add(b)
        if not b.finished or b.finished:sub(1, 4) ~= tostring(year) then return end
        local norm = (b.title or ""):lower():gsub("[^%w]", "")
        if norm == "" or seen[norm] then return end
        seen[norm] = true
        books[#books + 1] = b
    end
    local ok_a, amazon = pcall(require, "qs_amazon_finished")
    if ok_a and type(amazon) == "table" then
        for _, b in ipairs(amazon) do add(b) end
    end
    local ok_h, ReadHistory = pcall(require, "readhistory")
    if ok_h then
        for _, e in ipairs(ReadHistory.hist or {}) do
            if e.file and DocSettings:hasSidecarFile(e.file) then
                local ds = DocSettings:open(e.file)
                local summary = ds:readSetting("summary") or {}
                if summary.status == "complete" and summary.modified then
                    local props = ds:readSetting("doc_props") or {}
                    add{
                        finished = summary.modified, title = props.title or e.file:match("([^/]+)%.[^.]+$"),
                        author = props.authors, series = props.series, n = tonumber(props.series_index),
                        file = e.file,
                    }
                end
            end
        end
    end
    table.sort(books, function(a, b) return a.finished < b.finished end)
    return books
end

local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September",
    "October", "November", "December" }
local NUMBERS = { "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" }
D.MONTHS = MONTHS

local function highlights(books)
    local out = {}
    -- Fastest run: books of one series finished back to back (at most two weeks apart): most books, then
    -- fewest days.
    local by_series = {}
    for _, b in ipairs(books) do
        if b.series then
            by_series[b.series] = by_series[b.series] or {}
            table.insert(by_series[b.series], b)
        end
    end
    local best
    for series, list in pairs(by_series) do
        local run = { list[1] }
        local function consider()
            if #run >= 3 then
                local days = math.floor((parse(run[#run].finished) - parse(run[1].finished)) / 86400 + 0.5) + 1
                if not best or #run > best.count or (#run == best.count and days < best.days) then
                    best = { series = series, first = run[1], last = run[#run], count = #run, days = days }
                end
            end
        end
        for i = 2, #list do
            local gap = (parse(list[i].finished) - parse(list[i - 1].finished)) / 86400
            if gap <= 14 then
                run[#run + 1] = list[i]
            else
                consider()
                run = { list[i] }
            end
        end
        consider()
    end
    if best then
        local a, b = parse(best.first.finished), parse(best.last.finished)
        local span
        if os.date("%m", a) == os.date("%m", b) then
            span = string.format("%d–%d %s", tonumber(os.date("%d", a)), tonumber(os.date("%d", b)), MONTHS[tonumber(os.date("%m", b))])
        else
            span = string.format("%d %s – %d %s", tonumber(os.date("%d", a)), MONTHS[tonumber(os.date("%m", a))]:sub(1, 3),
                tonumber(os.date("%d", b)), MONTHS[tonumber(os.date("%m", b))]:sub(1, 3))
        end
        local range = (best.first.n and best.last.n) and string.format(" %d–%d", best.first.n, best.last.n) or ""
        out[#out + 1] = { icon = "bolt", title = "Fastest run",
            text = string.format("%s%s in %d days, %s", best.series, range, best.days, span) }
    end
    -- Biggest month.
    local per_month = {}
    for _, b in ipairs(books) do
        local m = tonumber(b.finished:sub(6, 7))
        per_month[m] = (per_month[m] or 0) + 1
    end
    local top_m, top_n = nil, 0
    for m = 1, 12 do
        if (per_month[m] or 0) > top_n then top_m, top_n = m, per_month[m] end
    end
    if top_m and top_n >= 2 then
        local in_month, top_s, top_c = {}, nil, 0
        for _, b in ipairs(books) do
            if tonumber(b.finished:sub(6, 7)) == top_m and b.series then
                in_month[b.series] = (in_month[b.series] or 0) + 1
                if in_month[b.series] > top_c then top_s, top_c = b.series, in_month[b.series] end
            end
        end
        local text = string.format("%s: %d books", MONTHS[top_m], top_n)
        if top_s and top_c >= 2 then
            text = text .. string.format(", %s of them %s", NUMBERS[top_c] or tostring(top_c), top_s)
        end
        out[#out + 1] = { icon = "calendar", title = "Biggest month", text = text }
    end
    -- Most-read series.
    local top_series, count = nil, 0
    for series, list in pairs(by_series) do
        if #list > count then top_series, count = series, #list end
    end
    if top_series and count >= 2 then
        out[#out + 1] = { icon = "series", title = "Most-read series",
            text = string.format("%s, %d books this year", top_series, count) }
    end
    return out
end

-- Everything both views need. Cheap enough to run on every visit (one query for the days, one for pace).
function D.collect()
    local today = noonOf(os.time())
    local by_day, order = secondsByDay()
    local read = {}
    for d, secs in pairs(by_day) do
        if secs > 0 then read[d] = true end
    end
    local streak, marks = currentStreak(read, today)
    local s = {
        today = today,
        streak = streak,
        best = math.max(bestStreak(read, order, today), streak),
        weeks = weeksInRow(read, today),
        chain = {},
        this_week = {}, last_week = {},
        heat = {}, heat_start = addDays(mondayOf(today), -7 * (HEAT_WEEKS - 1)),
    }
    for i = 6, 0, -1 do
        local t = addDays(today, -i)
        local k = key(t)
        s.chain[#s.chain + 1] = { t = t, state = marks[k] or (i == 0 and "today") or "none",
            letter = os.date("%a", t):sub(1, 1) }
    end
    local monday = mondayOf(today)
    for i = 0, 6 do
        s.this_week[i + 1] = by_day[key(addDays(monday, i))] or 0
        s.last_week[i + 1] = by_day[key(addDays(monday, i - 7))] or 0
    end
    s.this_total, s.last_total = 0, 0
    for i = 1, 7 do
        s.this_total = s.this_total + s.this_week[i]
        s.last_total = s.last_total + s.last_week[i]
    end
    for w = 0, HEAT_WEEKS - 1 do
        for d = 0, 6 do
            local t = addDays(s.heat_start, w * 7 + d)
            s.heat[#s.heat + 1] = t <= today and (by_day[key(t)] or 0) or -1
        end
    end
    s.first_day = order[1]
    -- the book being read, time left and the finish date at the recent pace
    local book = currentBook()
    if book then
        -- time left to the end of the story at your pace, as on Home (quiet_readtime.lua)
        local ok_rt, info = pcall(function() return require("quiet_readtime").forFile(book.file) end)
        if ok_rt and info and info.left_secs then
            book.secs_left = info.left_secs
        else
            book.secs_left = math.max(0, book.pages * (1 - book.pct)) * secsPerPage(book.md5)
        end
        local span = 14
        if s.first_day then
            span = math.max(1, math.min(14, math.floor((today - parse(s.first_day)) / 86400 + 0.5) + 1))
        end
        local recent, reading_days = 0, 0
        for i = 0, span - 1 do
            local secs = by_day[key(addDays(today, -i))] or 0
            recent = recent + secs
            if secs > 0 then reading_days = reading_days + 1 end
        end
        local per_day = recent / span
        -- a pace needs a few days behind it: one evening's reading says little about the next month
        if reading_days >= 3 and per_day >= 120 and book.secs_left > 0 then
            book.finish = addDays(today, math.ceil(book.secs_left / per_day))
        end
        s.book = book
    end
    -- the year
    local year = tonumber(os.date("%Y", today))
    local books = finishedBooks(year)
    s.year, s.books = year, books
    s.per_month = {}
    for m = 1, 12 do s.per_month[m] = 0 end
    for _, b in ipairs(books) do
        local m = tonumber(b.finished:sub(6, 7))
        s.per_month[m] = s.per_month[m] + 1
    end
    s.month_now = tonumber(os.date("%m", today))
    s.highlights = highlights(books)
    return s
end

return D
