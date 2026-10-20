--[[
What Claude gets to read when asked about the book (Search & Ask), and the background-process helper the
sheet's slow work runs in.

  - Page texts come out of the document page by page, in a background process (the reader keeps its position
    and stays responsive), and are kept for the rest of the session; a new text size or margin re-lays the book
    out, which changes the fingerprint and starts the cache afresh.
  - Each page starts with a marker "[p 12]" in the toolbar's own page numbers, so Claude can cite pages that
    the sheet turns into links.
  - What's sent (see docs/design.md):
      1. the chapters before the current one, at most BEFORE_CAP_CHARS (~100k tokens), dropped from the
         beginning a whole chapter at a time; the titles of what was dropped are listed instead. This block only
         changes when a chapter ends, so it's the one marked for Anthropic's prompt cache;
      2. the current chapter up to the end of the page being read;
      3. the focus: the page itself, or the passage that was selected;
      4. with "What's ahead" on, the rest of the book after the page, at most AHEAD_CAP_CHARS, cut at the end.
  - The system text never mentions the page number (it would break the cache on every page turn); where the
    reader is goes into the question instead (see quiet_ask.lua).

assemble() is plain Lua (tests: scratchpad/tests/a1/test_bookctx.lua).
]]

local BookCtx = {}

BookCtx.BEFORE_CAP_CHARS = 400000 -- ~100k tokens of earlier chapters
BookCtx.AHEAD_CAP_CHARS = 320000  -- ~80k tokens after the page, when What's ahead is on
BookCtx.CURRENT_CAP_CHARS = 400000 -- a chapter longer than this keeps its last part only
BookCtx.VIRTUAL_CHAPTER = 20      -- pages per "chapter" in a book without a table of contents
BookCtx.MAX_TRIMMED_TITLES = 40

--[[ Run task() in a child process (a copy of KOReader at this moment: the document can be read, and moving
around in it there doesn't move the reader). done(result) or done(nil, message) arrives on the main loop.
The result must be plain data (strings, numbers, booleans, tables). Returns a job with :cancel(). ]]
function BookCtx.runAsync(task, done)
    local UIManager = require("ui/uimanager")
    local ffiutil = require("ffi/util")
    local buffer = require("string.buffer")
    local pid, fd = ffiutil.runInSubProcess(function(_, wfd)
        local ok, res = pcall(task)
        local okenc, str = pcall(buffer.encode, ok and { ok = true, res = res } or { ok = false, err = tostring(res) })
        if not okenc then str = buffer.encode({ ok = false, err = "the result couldn't be passed back" }) end
        ffiutil.writeToFD(wfd, str, true)
    end, true)
    -- the child's own process group from this side too, so a cancel right away still reaches it (see quiet_net)
    if pid then pcall(function() require("quiet_net")._ownGroup(pid) end) end
    local job = { done = false }
    if not pid then
        job.done = true
        UIManager:nextTick(function() done(nil, "couldn't start a background task") end)
        function job:cancel() end
        return job
    end
    local function reap()
        if not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(2, reap) end
    end
    local interval = 0.05
    local poll
    poll = function()
        if job.done then return end
        local finished = ffiutil.isSubProcessDone(pid)
        local avail = fd and ffiutil.getNonBlockingReadSize(fd) or 0
        if finished or avail > 0 then
            job.done = true
            local data = fd and ffiutil.readAllFromFD(fd) or ""
            fd = nil
            if not finished then UIManager:scheduleIn(1, reap) end
            local ok, t = pcall(buffer.decode, data)
            if ok and type(t) == "table" and t.ok then
                done(t.res)
            else
                done(nil, ok and type(t) == "table" and t.err or "the background task stopped")
            end
            return
        end
        interval = math.min(interval * 1.5, 0.4)
        UIManager:scheduleIn(interval, poll)
    end
    UIManager:scheduleIn(interval, poll)
    function job:cancel()
        if self.done then return end
        self.done = true
        UIManager:unschedule(poll)
        local killed = pcall(function() require("quiet_net")._killChild(pid) end)
        if not killed then ffiutil.terminateSubProcess(pid) end
        local function cleanup()
            if fd and (ffiutil.isSubProcessDone(pid) or (ffiutil.getNonBlockingReadSize(fd) or 0) > 0) then
                ffiutil.readAllFromFD(fd) -- also closes it
                fd = nil
            end
            if fd or not ffiutil.isSubProcessDone(pid) then UIManager:scheduleIn(2, cleanup) end
        end
        UIManager:scheduleIn(1, cleanup)
    end
    return job
end

-- The page the reader is on, in the toolbar's numbers: CRE documents know it themselves, paged ones (PDF, DjVu,
-- comics) only through the reader's paging module.
function BookCtx.currentPage(ui)
    local p = ui.paging and ui.paging.current_page
    if p and p > 0 then return p end
    local doc = ui.document
    if doc and doc.getCurrentPage then return doc:getCurrentPage() end
    return 1
end

-- Page texts of the open book, kept while its layout stays the same.
local store = { doc = nil, key = nil, pages = {} }

function BookCtx.fingerprint(doc)
    local n = doc:getPageCount()
    local ok, xp = pcall(function() return doc:getPageXPointer(math.max(1, math.floor(n / 2))) end)
    return n .. "|" .. tostring(ok and xp or "")
end

-- Let go of the page texts (the book closed).
function BookCtx.forget()
    store = { doc = nil, key = nil, pages = {} }
end

function BookCtx.store(ui)
    local doc = ui.document
    local key = BookCtx.fingerprint(doc)
    if store.doc ~= doc or store.key ~= key then
        store = { doc = doc, key = key, pages = {} }
    end
    return store
end

local function pageTextToString(t)
    if type(t) == "string" then return t end
    local lines = {}
    if type(t) == "table" then
        for _, line in ipairs(t) do
            if type(line) == "table" then
                local words = {}
                for i = 1, #line do
                    if type(line[i]) == "table" and line[i].word then words[#words + 1] = line[i].word end
                end
                lines[#lines + 1] = table.concat(words, " ")
            end
        end
    end
    return table.concat(lines, "\n")
end

-- The text of the listed pages, read in a background process. done(texts) with texts[page] = string.
function BookCtx.extract(ui, list, done)
    local doc = ui.document
    local rolling = ui.rolling ~= nil
    return BookCtx.runAsync(function()
        local out = {}
        local n = doc:getPageCount()
        if rolling then
            local end_xp
            for _, p in ipairs(list) do
                local a = doc:getPageXPointer(p)
                local b
                if p < n then
                    b = doc:getPageXPointer(p + 1)
                else
                    if end_xp == nil then
                        local ok, xp = pcall(function() return doc:getPageXPointer(n + 1) end)
                        if not (ok and xp and xp ~= a) then
                            -- this is a copy of the reader: moving to the very end here moves nothing on screen
                            pcall(function()
                                doc:gotoPos(2 ^ 30)
                                xp = doc:getXPointer()
                            end)
                        end
                        end_xp = xp or false
                    end
                    b = end_xp or nil
                end
                local text = ""
                if a and b and a ~= b then
                    text = doc:getTextFromXPointers(a, b, false) or ""
                end
                out[p] = text
            end
        else
            -- PDF and DjVu have a text layer per page, as lines of word boxes (getPageTextBoxes: the generic
            -- getPageText is PDF-only, DjVu's pages don't have it); a scan or a comic page has none: empty then
            for _, p in ipairs(list) do
                local ok, t = pcall(function()
                    if doc.getPageTextBoxes then return doc:getPageTextBoxes(p) end
                    return doc:getPageText(p)
                end)
                out[p] = ok and pageTextToString(t) or ""
            end
        end
        return out
    end, done)
end

-- Make sure pages 1..last are in the store. progress(count) is called first when pages need reading.
-- done(store_pages) or done(nil, message). Returns a job (or nil when nothing had to be read).
function BookCtx.ensure(ui, last, progress, done)
    local s = BookCtx.store(ui)
    local missing = {}
    for p = 1, last do
        if not s.pages[p] then missing[#missing + 1] = p end
    end
    if #missing == 0 then
        done(s.pages)
        return nil
    end
    if progress then progress(#missing) end
    return BookCtx.extract(ui, missing, function(texts, err)
        if not texts then
            done(nil, err)
            return
        end
        for p, t in pairs(texts) do s.pages[p] = t end
        done(s.pages)
    end)
end

--[[ Chapter starts for trimming and caching: the top level of the table of contents (two levels when the top
one is only a few parts), as sorted pages, plus the title at each. ]]
function BookCtx.chapters(ui)
    local ticks, titles = {}, {}
    local toc = ui.toc
    if toc then
        pcall(function() toc:fillToc() end)
        local entries = toc.toc or {}
        local function collect(maxdepth)
            local seen, list, names = {}, {}, {}
            for _, e in ipairs(entries) do
                if e.page and (e.depth or 1) <= maxdepth and not seen[e.page] then
                    seen[e.page] = true
                    list[#list + 1] = e.page
                    names[e.page] = e.title
                end
            end
            table.sort(list)
            return list, names
        end
        ticks, titles = collect(1)
        if #ticks < 3 then ticks, titles = collect(2) end
    end
    return ticks, titles
end

-- The chapter the page is in: its first page.
function BookCtx.chapterStart(ticks, page)
    if not ticks or #ticks == 0 then
        return math.floor((page - 1) / BookCtx.VIRTUAL_CHAPTER) * BookCtx.VIRTUAL_CHAPTER + 1
    end
    local start = 1
    for _, t in ipairs(ticks) do
        if t <= page then start = t else break end
    end
    return start
end

local function cleanTitle(t)
    return ((t or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function pagesText(pages, from, to, titles)
    local parts = {}
    for p = from, to do
        if titles and titles[p] and cleanTitle(titles[p]) ~= "" then
            parts[#parts + 1] = "=== " .. cleanTitle(titles[p]) .. " ==="
        end
        parts[#parts + 1] = "[p " .. p .. "]"
        parts[#parts + 1] = (pages[p] or ""):gsub("\n\n+", "\n")
    end
    return table.concat(parts, "\n")
end

local function size(pages, from, to)
    local n = 0
    for p = from, to do n = n + #(pages[p] or "") + 8 end
    return n
end

--[[ Decide what Claude reads.
args = { pages = {[n] = text}, current = n, total = N, ticks = {...}, titles = {[page] = title}, ahead = bool,
         focus_text = selected text or nil, focus_page = page of the selection or nil }
returns { before = text or nil (cacheable), current = text, ahead = text or nil, first_page, last_page,
          trimmed = {titles left out}, partial = bool (the earliest chapter sent starts mid-way),
          chapter_start, focus = text, focus_page, focus_kind = "page" | "selection" } ]]
function BookCtx.assemble(args)
    local pages, n, total = args.pages, args.current, args.total
    local ticks, titles = args.ticks or {}, args.titles or {}
    local c = BookCtx.chapterStart(ticks, n)
    local ctx = { page = n, chapter_start = c, trimmed = {}, partial = false }

    -- 2. the current chapter up to the end of this page (its last part only, if it's enormous)
    local cur_from = c
    while cur_from < n and size(pages, cur_from, n) > BookCtx.CURRENT_CAP_CHARS do cur_from = cur_from + 1 end
    ctx.current = pagesText(pages, cur_from, n, titles)
    ctx.first_page = cur_from

    -- 1. earlier chapters, newest first, while they fit
    if cur_from == c and c > 1 then
        local ranges = {}
        local starts = {}
        if #ticks == 0 then
            for s = 1, c - 1, BookCtx.VIRTUAL_CHAPTER do starts[#starts + 1] = s end
        else
            if ticks[1] > 1 then starts[1] = 1 end
            for _, t in ipairs(ticks) do
                if t < c then starts[#starts + 1] = t end
            end
        end
        for i, s in ipairs(starts) do
            ranges[i] = { from = s, to = (starts[i + 1] or c) - 1, title = titles[s] }
        end
        -- another AI service may have a much smaller context window: the budget the question was asked with
        -- (args.budget, keys.lua's book_tokens via quiet_claude.bookChars), fixed then (review C8-4, round 3)
        local budget = args.budget or BookCtx.BEFORE_CAP_CHARS
        local first_included = #ranges + 1
        for i = #ranges, 1, -1 do
            local r = ranges[i]
            local sz = size(pages, r.from, r.to)
            if sz <= budget then
                budget = budget - sz
                first_included = i
            else
                if first_included == #ranges + 1 then
                    -- the chapter just before is bigger than the whole budget: its last part
                    local from = r.from
                    while from < r.to and size(pages, from, r.to) > budget do from = from + 1 end
                    r.from = from
                    first_included = i
                    ctx.partial = true
                end
                break
            end
        end
        for i = 1, first_included - 1 do
            local t = cleanTitle(ranges[i].title)
            if t ~= "" then ctx.trimmed[#ctx.trimmed + 1] = t end
        end
        while #ctx.trimmed > BookCtx.MAX_TRIMMED_TITLES do table.remove(ctx.trimmed, 1) end
        if first_included <= #ranges then
            local from, to = ranges[first_included].from, c - 1
            local head = {}
            if #ctx.trimmed > 0 then
                head[#head + 1] = "Earlier chapters, left out to keep this short: " .. table.concat(ctx.trimmed, "; ") .. "."
            end
            if ctx.partial then head[#head + 1] = "(This starts part-way into a chapter.)" end
            head[#head + 1] = pagesText(pages, from, to, titles)
            ctx.before = table.concat(head, "\n")
            ctx.first_page = from
        end
    end

    -- 4. what's ahead, from the next page on, while it fits
    ctx.last_page = n
    if args.ahead and n < total then
        local to, used = n, 0
        while to < total do
            local sz = #(pages[to + 1] or "") + 8
            if used + sz > BookCtx.AHEAD_CAP_CHARS then break end
            used = used + sz
            to = to + 1
        end
        if to > n then
            ctx.ahead = pagesText(pages, n + 1, to, titles)
            ctx.last_page = to
        end
    end

    -- whether that is any of the book's own text (a scanned PDF has pages but no text layer): bytes that aren't
    -- ASCII spaces or punctuation, so letters of any script count (%w alone knows only ASCII: review C4-R3-2)
    local letters = 0
    for p = ctx.first_page, ctx.last_page do
        local _, k = (pages[p] or ""):gsub("[^%s%p]", "")
        letters = letters + k
    end
    ctx.letters = letters

    -- 3. the focus
    if args.focus_text and args.focus_text ~= "" then
        ctx.focus, ctx.focus_kind, ctx.focus_page = args.focus_text, "selection", args.focus_page or n
    else
        ctx.focus, ctx.focus_kind, ctx.focus_page = pages[n] or "", "page", n
    end
    return ctx
end

-- Everything the sheet needs for a question: done(ctx) or done(nil, message). progress(pages_to_read).
function BookCtx.build(ui, opts, progress, done)
    local doc = ui.document
    local n, total = BookCtx.currentPage(ui), doc:getPageCount()
    local last = opts.ahead and total or n
    return BookCtx.ensure(ui, last, progress, function(pages, err)
        if not pages then
            done(nil, err)
            return
        end
        local ticks, titles = BookCtx.chapters(ui)
        local ctx = BookCtx.assemble{
            pages = pages, current = n, total = total, ticks = ticks, titles = titles, ahead = opts.ahead,
            focus_text = opts.focus_text, focus_page = opts.focus_page, budget = opts.budget,
        }
        ctx.total = total
        ctx.chapter = ui.toc and ui.toc:getTocTitleByPage(n) or ""
        done(ctx)
    end)
end

-- The system text: the book and the rules. Kept identical for a book (and switch position) on purpose: it's part
-- of the cached prefix, so anything that changes per page belongs in the question.
function BookCtx.system(props, ahead)
    local title = props and (props.display_title or props.title) or ""
    local author = props and props.authors and props.authors:gsub("\n", ", ") or ""
    local lines = {
        "You're helping someone who is reading " .. (title ~= "" and ("“" .. title .. "”") or "a book")
            .. (author ~= "" and (" by " .. author) or "") .. " on a Kindle.",
        "The book's text is in the first message, with page markers like [p 12] and chapter titles marked with ===.",
        "",
        "- Answer from that text. Cite the pages you rely on like this: (p 12) or (p 15–16).",
    }
    if ahead then
        lines[#lines + 1] = "- The text includes what comes after the reader's page, because they asked for it. You may use it; "
            .. "say when something happens later than where they are."
    else
        lines[#lines + 1] = "- The text stops at the reader's page. Use nothing you may know about this book beyond it: no hints "
            .. "about what happens later, no spoilers, not even to say that something will matter."
    end
    lines[#lines + 1] = "- If the text doesn't answer the question, say so plainly in one sentence."
    lines[#lines + 1] = "- Keep it short: plain sentences for a small e-ink screen, a few short paragraphs at most. "
        .. "No headings, tables or bold; a list only when asked for one (one short line per item)."
    return table.concat(lines, "\n")
end

-- The book blocks for Claude.stream (the earlier chapters marked for the cache).
function BookCtx.blocks(ctx)
    local book = {}
    if ctx.before then
        book[#book + 1] = { text = "The book up to the current chapter:\n" .. ctx.before, cache = true }
    end
    book[#book + 1] = { text = "The current chapter, up to the end of the reader's page:\n" .. ctx.current }
    if ctx.ahead then
        book[#book + 1] = { text = "After the reader's page:\n" .. ctx.ahead }
    end
    return book
end

return BookCtx
