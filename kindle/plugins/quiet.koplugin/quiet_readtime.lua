--[[
Quiet reading time: one honest answer to "how long have I read this book" and "how long is left", shared by
Home's Currently Reading card, the Library list, the reader's footer and toolbar, and the Stats page, so they
always agree about the same book.

What KOReader records (statistics plugin): one row per page visit, the time from arriving on a page to leaving
it. Visits under 5 s aren't kept. A visit over 2 min is kept as exactly 2 min (its max_sec), and time asleep is
taken out. So a book left open on a page until the Kindle dozes off still counts as 2 full minutes, and
KOReader's average (2-minute pages included) is what made Home say "12h 56m left" for a book with a few hours to go.

The rule here, in plain words:
  1. Your pace is your usual time on a page: the median of your ordinary visits (8 s to under 2 min), the last
     300 of them, mixed with a starting guess until there are enough (the guess weighs as much as 8 pages).
     The guess is your pace across other books, or 40 s before there are any: a test book had
     85,177 words over 579 pages at a typical text size (147 a page), and adults read about 238 words a minute
     (Brysbaert 2019), so 37 s.
  2. A page counts for at most twice your usual time: genuinely slow pages stay, coffee breaks don't.
  3. A page where KOReader stopped the clock at 2 min (you were away) counts as a usual page, unless pages that
     long are normal for you (then it counts nearer the full 2 min; the share comes from how spread out your
     own page times are, assuming 1 visit in 20 includes stepping away). Rule 2 still caps it.
  4. Time left is the pages to the end of the story (not the notes and index after it, see quiet_finish.lua)
     at your pace.
Rows for the same page closer than 5 s apart are one visit (a re-layout splits a visit in two). Page numbers
are rescaled when the text size changed since a row was recorded, as KOReader's own page_stat view does.

Use it lazily (require at the moment of use):
    local RT = require("quiet_readtime")
    RT.forFile(path)  -- { pct, read_secs, left_secs, pace, pages, status, finished, days } or nil (never opened)
    RT.forUI(ui, opts) -- the same for the open book, including the visits KOReader hasn't saved yet
                       -- (opts.upto: also count pages read up to here; opts.also: pages to count as read)
    RT.pace(ui)       -- seconds per page for the open book
    RT.format(secs)   -- "42 min", "4 h 12 min"
    RT.secondsByDay() -- { ["2026-10-19"] = secs, ... }, order: the days in order (Stats page)
]]

local RT = {}

RT.PRIOR_PACE = 40      -- seconds a page before there's any history (see 1. above)
RT.PRIOR_WEIGHT = 8     -- the starting guess weighs as much as this many pages of your own
RT.WINDOW = 300         -- pace from the most recent ordinary visits
RT.MIN_SAMPLE = 8       -- visits shorter than this are flips, not reading (only for the pace)
RT.CAP = 2              -- a page counts for at most this many usual pages
RT.SIGMA = 0.45         -- spread of page times (log scale) until there are 20 visits to measure it
RT.AWAY = 0.05          -- share of page visits that include stepping away
RT.MERGE_GAP = 5        -- rows for the same page this close together are one visit

local DB_NAME = "statistics.sqlite3"

local function median(list)
    local n = #list
    if n == 0 then return nil end
    local t = {}
    for i = 1, n do t[i] = list[i] end
    table.sort(t)
    if n % 2 == 1 then return t[(n + 1) / 2] end
    return (t[n / 2] + t[n / 2 + 1]) / 2
end

-- Abramowitz & Stegun 7.1.26 (error < 2e-7): enough for a share of page visits.
local function erfc(x)
    if x < 0 then return 2 - erfc(-x) end
    local t = 1 / (1 + 0.3275911 * x)
    local poly = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))))
    return poly * math.exp(-x * x)
end

local function censorSecs()
    local s = G_reader_settings and G_reader_settings:readSetting("statistics")
    return (type(s) == "table" and tonumber(s.max_sec)) or 120
end

-- Current-layout pages covered by page p of a tp-page layout (KOReader's page_stat view, in Lua).
local function pageRange(p, tp, n)
    if not tp or tp <= 0 or not n or n <= 0 or tp == n then return p, p end
    local first = math.floor((p - 1) * n / tp) + 1
    return first, math.max(first, math.floor(p * n / tp))
end

--[[
The core, no KOReader needed (unit-tested on the laptop). visits: { page, start, dur, tp } in any order
(tp = page count when recorded). opts: pages (current layout), prior (pace guess), censor (KOReader's max_sec),
upto (also count distinct pages read at or before this page), also (pages to count as read that statistics
hasn't recorded: { page, tp } like a visit, tp nil for the current layout; quiet_finish.lua passes the page being
left and, when statistics isn't recording, the pages read this session).
]]
function RT.compute(visits, opts)
    opts = opts or {}
    local n_pages = opts.pages
    local censor = opts.censor or 120
    local sorted = {}
    for i, v in ipairs(visits) do sorted[i] = v end
    table.sort(sorted, function(a, b) return a.start < b.start end)

    local merged = {}
    for _, v in ipairs(sorted) do
        local last = merged[#merged]
        if last and last.page == v.page and last.tp == v.tp and v.start <= last.start + last.dur + RT.MERGE_GAP then
            last.dur = last.dur + v.dur
            last.capped = last.capped or v.dur >= censor
        else
            merged[#merged + 1] = { page = v.page, start = v.start, dur = v.dur, tp = v.tp, capped = v.dur >= censor }
        end
    end

    local function perPage(v, secs)
        if n_pages and n_pages > 0 and v.tp and v.tp > 0 then return secs * v.tp / n_pages end
        return secs
    end

    -- 1. pace
    local sample = {}
    for i = #merged, 1, -1 do
        local v = merged[i]
        if not v.capped and v.dur >= RT.MIN_SAMPLE and v.dur < censor then
            sample[#sample + 1] = perPage(v, v.dur)
            if #sample >= RT.WINDOW then break end
        end
    end
    local prior = opts.prior or RT.PRIOR_PACE
    local med = median(sample)
    local n = #sample
    local pace = med and (n * med + RT.PRIOR_WEIGHT * prior) / (n + RT.PRIOR_WEIGHT) or prior
    pace = math.max(5, math.min(pace, 300))

    local sigma = RT.SIGMA
    if n >= 20 then
        local dev = {}
        for i, s in ipairs(sample) do dev[i] = math.abs(math.log(s / med)) end
        sigma = math.max(0.25, math.min(1.4826 * median(dev), 0.8))
    end

    -- 2. and 3. count each visit
    local read, days, seen, upto_seen = 0, {}, {}, {}
    local nd, n_seen, n_upto = 0, 0, 0
    for _, v in ipairs(merged) do
        local usual = (n_pages and n_pages > 0 and v.tp and v.tp > 0) and pace * n_pages / v.tp or pace
        local count
        if v.capped or v.dur >= censor then
            local z = math.log(math.max(censor, v.dur) / usual) / sigma
            local tail = 0.5 * erfc(z / math.sqrt(2))
            local p_reading = tail / (tail + RT.AWAY)
            count = math.min(usual, censor) * (1 - p_reading) + censor * p_reading
        else
            count = v.dur
        end
        count = math.min(count, RT.CAP * usual)
        read = read + count
        if opts.days ~= false then
            local day = os.date("%Y-%m-%d", v.start)
            if not days[day] then days[day] = true nd = nd + 1 end
        end
        local a, b = pageRange(v.page, v.tp, n_pages)
        for p = a, b do
            if not seen[p] then seen[p] = true n_seen = n_seen + 1 end
            if opts.upto and p <= opts.upto and not upto_seen[p] then upto_seen[p] = true n_upto = n_upto + 1 end
        end
        v.count = count
    end
    for _, extra in ipairs(opts.also or {}) do
        local a, b = pageRange(extra.page, extra.tp, n_pages)
        for p = a or 1, b or 0 do
            if not seen[p] then seen[p] = true n_seen = n_seen + 1 end
            if opts.upto and p <= opts.upto and not upto_seen[p] then upto_seen[p] = true n_upto = n_upto + 1 end
        end
    end
    return {
        read_secs = read, pace = pace, sigma = sigma, samples = n, days = nd,
        pages_read = n_seen, pages_read_upto = opts.upto and n_upto or nil, visits = merged,
    }
end

function RT.format(secs)
    secs = tonumber(secs) or 0
    local mins = math.floor(secs / 60 + 0.5)
    if secs > 0 and mins < 1 then mins = 1 end
    if mins < 60 then return mins .. " min" end
    local h, m = math.floor(mins / 60), mins % 60
    return m > 0 and string.format("%d h %d min", h, m) or (h .. " h")
end

-- A book's percent in words, rounded the way Home's card (SimpleUI) and the footer round it, so the Library and the
-- sleep screen say the same number ("2%", not "1%" next to Home's "2% done"); a book just started says 1%, not 0%.
function RT.percentText(pct)
    pct = tonumber(pct) or 0
    return string.format("%d%%", math.max(pct > 0 and 1 or 0, math.floor(pct * 100 + 0.5)))
end

-- Database access ------------------------------------------------------------------------------------------

local cache = { sig = false }

local function dbPath()
    return require("datastorage"):getSettingsDir() .. "/" .. DB_NAME
end

-- Changes whenever KOReader saves page visits (it writes through the WAL file first).
local function dbSignature()
    local lfs = require("libs/libkoreader-lfs")
    local p = dbPath()
    local a, w = lfs.attributes(p), lfs.attributes(p .. "-wal")
    return string.format("%s:%s:%s:%s", a and a.modification or 0, a and a.size or 0,
        w and w.modification or 0, w and w.size or 0)
end

local function fresh()
    local sig = dbSignature()
    if cache.sig ~= sig then cache = { sig = sig, rows = {}, files = {}, prior = {} } end
    return cache
end

local function withDB(conn, fn)
    local logger = require("logger")
    if conn then
        local ok, res = pcall(fn, conn)
        if not ok then logger.warn("quiet readtime:", res) end
        return ok and res or nil
    end
    local lfs = require("libs/libkoreader-lfs")
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq or lfs.attributes(dbPath(), "mode") ~= "file" then return nil end
    local ok_o, c = pcall(SQ3.open, dbPath())
    if not ok_o or not c then return nil end
    local ok, res = pcall(fn, c)
    pcall(c.close, c)
    if not ok then logger.warn("quiet readtime:", res) end
    return ok and res or nil
end

local function query(c, sql, ...)
    local stmt = c:prepare(sql)
    local res, nb = stmt:reset():bind(...):resultset("i")
    stmt:close()
    return res or {}, nb or 0
end

-- This book's recorded visits, by the md5 KOReader keeps for it.
local function bookRows(md5, conn)
    local c = fresh()
    if c.rows[md5] then return c.rows[md5] end
    local rows = withDB(conn, function(db)
        local res, nb = query(db, [[
            SELECT d.page, d.start_time, d.duration, d.total_pages
            FROM page_stat_data d JOIN book b ON b.id = d.id_book
            WHERE b.md5 = ? ORDER BY d.start_time;]], md5)
        local out = {}
        for i = 1, nb do
            out[i] = { page = tonumber(res[1][i]), start = tonumber(res[2][i]), dur = tonumber(res[3][i]),
                tp = tonumber(res[4][i]) }
        end
        return out
    end) or {}
    c.rows[md5] = rows
    return rows
end

-- The starting guess: your pace in other books (each visit as a share of that book's own pages), once there
-- are 30 ordinary visits to go on.
local function priorFor(md5, conn)
    local c = fresh()
    local key = md5 or "-"
    if c.prior[key] then return c.prior[key] end
    local censor = censorSecs()
    local prior = withDB(conn, function(db)
        local res, nb = query(db, [[
            SELECT d.duration, d.total_pages, b.pages
            FROM page_stat_data d JOIN book b ON b.id = d.id_book
            WHERE d.duration >= ? AND d.duration < ? AND coalesce(b.md5, '') <> ?
            ORDER BY d.start_time DESC LIMIT 500;]], RT.MIN_SAMPLE, censor, key)
        if nb < 30 then return nil end
        local t = {}
        for i = 1, nb do
            local d, tp, pages = tonumber(res[1][i]), tonumber(res[2][i]), tonumber(res[3][i])
            t[#t + 1] = (tp and tp > 0 and pages and pages > 0) and d * tp / pages or d
        end
        return median(t)
    end) or RT.PRIOR_PACE
    c.prior[key] = prior
    return prior
end

-- The end of the story as a share of the book, from quiet_finish (nil: the book's end).
local function storyEndPct(se)
    return type(se) == "table" and tonumber(se.pct) or nil
end

local function leftSecs(pace, pages, pct, end_pct, status)
    if status == "complete" then return 0 end
    if not (pages and pages > 0 and pct) then return nil end
    return math.max(0, (end_pct or 1) - pct) * pages * pace
end

-- Books ------------------------------------------------------------------------------------------------------

function RT.forFile(path, opts)
    opts = opts or {}
    if not path then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local DocSettings = require("docsettings")
    local sidecar = DocSettings:findSidecarFile(path)
    if not sidecar then return nil end
    local c = fresh()
    local mtime = lfs.attributes(sidecar, "modification") or 0
    local hit = c.files[path]
    if hit and hit.mtime == mtime then return hit.info end

    local ds = DocSettings:open(path)
    local md5 = ds:readSetting("partial_md5_checksum")
    local pct = tonumber(ds:readSetting("percent_finished"))
    local summary = ds:readSetting("summary") or {}
    local info
    if md5 or pct or summary.status == "complete" then
        local pages = tonumber(ds:readSetting("doc_pages")) or (ds:readSetting("stats") or {}).pages
        local res = RT.compute(md5 and bookRows(md5, opts.conn) or {},
            { pages = pages, prior = priorFor(md5, opts.conn), censor = censorSecs() })
        info = {
            pct = pct or (summary.status == "complete" and 1 or 0),
            read_secs = res.read_secs,
            pace = res.pace,
            pages = pages,
            days = res.days,
            pages_read = res.pages_read,
            status = summary.status,
            finished = summary.status == "complete" and summary.modified or nil,
        }
        -- time left in pages of one layout: KOReader's saved percent counts within the main flow when non-linear
        -- fragments are hidden, and quiet_story_end.pct is from the layout it was worked out in; quiet_finish
        -- saves the page, the page count and the story end together for this
        local here, end_pct, left_pages = pct, storyEndPct(ds:readSetting("quiet_story_end")), pages
        local qp = ds:readSetting("quiet_position")
        local qpage, qpages = type(qp) == "table" and tonumber(qp.page), type(qp) == "table" and tonumber(qp.pages)
        if qpage and qpages and qpages > 0 then
            here, left_pages = qpage / qpages, qpages
            if tonumber(qp.story_end) then end_pct = (tonumber(qp.story_end) - 1) / qpages end
        end
        info.left_secs = leftSecs(res.pace, left_pages, here, end_pct, summary.status)
    end
    c.files[path] = { mtime = mtime, info = info }
    return info
end

-- The file KOReader's history has for this md5 (SimpleUI's card only knows the md5).
local md5_files = {}
function RT.fileForMd5(md5)
    if not md5 then return nil end
    local f = md5_files[md5]
    local lfs = require("libs/libkoreader-lfs")
    if f and lfs.attributes(f, "mode") == "file" then return f end
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok then return nil end
    local DocSettings = require("docsettings")
    for _, e in ipairs(ReadHistory.hist or {}) do
        if e.file and lfs.attributes(e.file, "mode") == "file" and DocSettings:findSidecarFile(e.file) then
            if DocSettings:open(e.file):readSetting("partial_md5_checksum") == md5 then
                md5_files[md5] = e.file
                return e.file
            end
        end
    end
end

-- The page on screen. Only CreDocument (EPUB and other reflowable books) has getCurrentPage(); PDFs, DjVu and
-- comics (paging documents) keep it in ui.paging.
function RT.currentPage(ui)
    if ui.paging and ui.paging.current_page then return ui.paging.current_page end
    local doc = ui.document
    return doc and doc.getCurrentPage and doc:getCurrentPage() or 1
end

-- The open book: saved visits plus the ones KOReader keeps in memory until it next writes (every 50 pages,
-- on sleep, on close).
local memo = {}
function RT.forUI(ui, opts)
    opts = opts or {}
    local doc = ui and ui.document
    if not doc then return nil end
    local md5 = ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum")
    local pages = doc:getPageCount()
    local page = RT.currentPage(ui)
    local sig = fresh().sig -- (also when there's no md5 yet, so the memo key below always has one)
    local visits = {}
    if md5 then
        for i, v in ipairs(bookRows(md5)) do visits[i] = v end
    end
    local n_db, mem_sum = #visits, 0
    local st = ui.statistics
    if st and type(st.page_stat) == "table" then
        local tp = st.data and tonumber(st.data.pages) or pages
        for p, list in pairs(st.page_stat) do
            for _, tuple in ipairs(list) do
                if (tuple[2] or 0) > 0 then
                    visits[#visits + 1] = { page = p, start = tuple[1], dur = tuple[2], tp = tp }
                    mem_sum = mem_sum + tuple[1] + tuple[2]
                end
            end
        end
    end
    local summary = ui.doc_settings and ui.doc_settings:readSetting("summary") or {}
    local se = ui.doc_settings and ui.doc_settings:readSetting("quiet_story_end")
    -- the footer and the toolbar both ask after a page turn: work it out once per change (the story end can
    -- move without a page turn when Jev answers, and the status changes when the book is marked finished)
    local key = table.concat({ tostring(md5), sig, n_db, #visits, mem_sum, pages, page, tostring(opts.upto),
        tostring(opts.also), type(se) == "table" and (tostring(se.xpointer) .. "|" .. tostring(se.page)) or "-",
        tostring(summary.status) }, ":")
    if memo.key == key and memo.ui == ui then return memo.info end
    local res = RT.compute(visits, { pages = pages, prior = priorFor(md5), censor = censorSecs(), upto = opts.upto,
        also = opts.also, days = false })
    local end_page = pages
    if type(se) == "table" then
        local ok, p = pcall(function()
            if se.xpointer and ui.rolling then return doc:getPageFromXPointer(se.xpointer) end
            return se.page
        end)
        if ok and tonumber(p) then end_page = math.max(1, tonumber(p) - 1) end
    end
    local left = summary.status == "complete" and 0 or math.max(0, end_page - page) * res.pace
    local info = {
        pct = pages > 0 and page / pages or 0,
        read_secs = res.read_secs,
        left_secs = left,
        pace = res.pace,
        pages = pages,
        page = page,
        story_end_page = end_page,
        pages_read = res.pages_read,
        pages_read_upto = res.pages_read_upto,
        status = summary.status,
    }
    memo.key, memo.ui, memo.info = key, ui, info
    return info
end

function RT.pace(ui)
    local info = RT.forUI(ui)
    return info and info.pace
end

-- Honest seconds read per local day, every book (each book's visits counted at its own pace).
function RT.secondsByDay()
    local c = fresh()
    if c.by_day then return c.by_day, c.day_order end
    local censor = censorSecs()
    local books = withDB(nil, function(db)
        local res, nb = query(db, [[
            SELECT coalesce(b.md5, 'id' || d.id_book), d.page, d.start_time, d.duration, d.total_pages, b.pages
            FROM page_stat_data d JOIN book b ON b.id = d.id_book ORDER BY d.start_time;]])
        local out = {}
        for i = 1, nb do
            local key = res[1][i]
            local b = out[key]
            if not b then
                b = { visits = {}, pages = tonumber(res[6][i]) }
                out[key] = b
            end
            b.visits[#b.visits + 1] = { page = tonumber(res[2][i]), start = tonumber(res[3][i]),
                dur = tonumber(res[4][i]), tp = tonumber(res[5][i]) }
        end
        return out
    end) or {}
    local by_day = {}
    for key, b in pairs(books) do
        local res = RT.compute(b.visits, { pages = b.pages, prior = priorFor(key), censor = censor })
        for _, v in ipairs(res.visits) do
            local day = os.date("%Y-%m-%d", v.start)
            by_day[day] = (by_day[day] or 0) + v.count
        end
    end
    local order = {}
    for day in pairs(by_day) do order[#order + 1] = day end
    table.sort(order)
    c.by_day, c.day_order = by_day, order
    return by_day, order
end

return RT
