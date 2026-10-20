--[[
Quiet finish: a book is marked finished when you reach the end of the story, not the end of the file. On
the books it was made with the story ends at 87% (a non-fiction book: notes, appendix and index follow) to 99%; Amazon's
reader stops at 94-99% for the same reason, and KOReader only asks at the very last page.

Where the story ends, from the book's contents: the run of back-matter entries at the end (Acknowledgments,
Notes, Index, Appendix, About the Author, Also by, excerpts and newsletter pages…). Walking back from the last
entry, anything that is plainly a chapter (Chapter 12, 44: Rise, Epilogue, Conclusion, Afterword, Coda) ends
the walk; the first back-matter entry after it is where the story ends. Entries that are neither (Dungeon
Crawler Carl's "It's that time again." note after the Epilogue) count as story when they come before the back
matter, so a book is never marked early. Appendices count as back matter: Thinking, Fast and Slow is finished
after Conclusions, not after the reprinted papers. Epilogues and afterwords count as story. Back matter never
starts before the middle of the book, and a walk through a dozen unknown entries stops (unnumbered chapters).
With a Jev key on the Kindle, a few unknown entries right after an Epilogue or Conclusion are put to Jev,
which may move the end earlier when it's sure (75%). No contents, or no back matter: the end of the book.
The place is kept in the book's settings as an xpointer, so a different text size doesn't move it.

When it marks: turning the page (a page turn, after 4 s or more on the page before) from the last story page
into the back matter, or closing the book on the last story page after reading it, and only if at least half
of the story's pages have been read in KOReader, the page just left included. A turn is a forward move made by
KOReader's page-turn entry point (GotoViewRel, in page or scroll mode); jumping to the notes or the index, the
scrubber, a link, the keypad or the contents never count, even when the jump lands on the next page, and nor
does skipping to the end to peek. "Read" is what KOReader's statistics recorded plus the pages you stayed on for
4 s or more in this session (statistics may be switched off for part of it), each kept with the page count of
the layout it was read in, so a text-size change rescales it like statistics' own rows. It marks the way KOReader's own "Mark as
finished" does (Library, Home, collections and Stats all follow), and shows "Finished · marked as read" with
Undo for a few seconds; Undo puts the book back to reading and it won't ask again for that book.
]]

local F = {}

F.VERSION = 1
F.MIN_SHARE = 0.5        -- back matter never starts before the middle of the book
F.MAX_UNKNOWN = 12       -- a longer run of unknown entries is chapters without numbers
F.COVERAGE = 0.5         -- share of the story's pages read in KOReader before it can be marked
F.MIN_DWELL = 4          -- seconds on the last page for a page turn to count as reading it
F.JEV_SURE = 0.75

-- Titles ---------------------------------------------------------------------------------------------------

local NUMBER_WORDS = { "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
    "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
    "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred" }

local STORY_START = { "chapter", "ch%.", "part", "book", "section", "volume", "prologue", "epilogue", "interlude",
    "conclusion", "conclusions", "afterword", "afterwards", "coda", "postscript", "introduction", "preface",
    "foreword", "the end", "finale", "act", "scene", "episode", "letter" }

local BACK_START = { "acknowledg", "dedication", "about the author", "about the authors", "about author",
    "about the publisher", "about the illustrator", "about the translator", "about the editor",
    "also by", "books by", "other books", "other titles", "more books", "more from", "more by",
    "by the same author", "also available", "coming soon", "excerpt", "an excerpt", "preview", "a preview",
    "sneak peek", "a sneak peek", "teaser", "bonus", "notes", "endnotes", "end notes", "footnotes",
    "chapter notes", "source notes", "works cited", "references", "bibliography", "selected bibliography",
    "sources", "further reading", "suggested reading", "recommended reading", "reading list", "resources",
    "online resources", "additional resources", "index", "glossary", "list of", "cast of characters",
    "dramatis personae", "characters", "genealogy", "family tree", "appendix", "appendices", "copyright",
    "credits", "photo credits", "photograph credits", "illustration credits", "image credits", "permissions",
    "reading group", "readers guide", "reader's guide", "discussion", "questions for discussion", "book club",
    "a conversation with", "conversation with", "q&a", "interview with", "summary of", "thank you for reading",
    "thanks for reading", "praise for", "advance praise", "newsletter", "mailing list", "sign up",
    "subscribe", "back cover", "appreciation", "contents", "table of contents",
    "colophon", "a note on the type", "note on the type", "a note on sources", "note on sources", "about this book" }

local BACK_ANYWHERE = { "facebook", "patreon", "mailing list", "newsletter", "excerpt from", "preview of",
    "sneak peek", "also by", "recommended reading", "reading group", "free book", "free ebook", "free story",
    "leave a review", "review this book" }

local function normalize(title)
    local t = (title or ""):lower()
    t = t:gsub("\u{2019}", "'"):gsub("\u{2018}", "'"):gsub("\u{201C}", '"'):gsub("\u{201D}", '"')
    t = t:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    return t
end

local function startsWord(t, word)
    if t:sub(1, #word) ~= word then return false end
    local nxt = t:sub(#word + 1, #word + 1)
    -- "acknowledg" and "ch." are stems; everything else must end at a word boundary
    return word == "acknowledg" or word:sub(-1) == "." or nxt == "" or not nxt:match("[%w']")
end

-- "story", "back", or nil (can't tell from the title).
function F.classify(title)
    local t = normalize(title)
    if t == "" then return nil end
    for _, w in ipairs(BACK_ANYWHERE) do
        if t:find(w, 1, true) then return "back" end
    end
    for _, w in ipairs(BACK_START) do
        if startsWord(t, w) then return "back" end
    end
    for _, w in ipairs(STORY_START) do
        if startsWord(t, w) then return "story" end
    end
    -- numbered: "44: Rise", "65.Facilities", "10 Conclusion", "XII. The Fall", "FOUR Overcoming…"
    if t:match("^%d+[%s%.:%)%-]") or t:match("^%d+$") then return "story" end
    if t:match("^[ivxlc]+[%.:%)]") or t:match("^[ivxlc]+$") then return "story" end
    -- a number word is a chapter when it's all of the title, shouted ("FOUR Overcoming…") or followed by a
    -- colon or full stop ("One: Arrival"); "One More!" is not a chapter
    local first = (title or ""):match("^%s*([%a%-]+)") or ""
    for _, w in ipairs(NUMBER_WORDS) do
        if startsWord(t, w) and (t == w or t:match("^" .. w .. "[%.:]")
                or (first:upper() == first and first:lower():sub(1, #w) == w)) then
            return "story"
        end
    end
    return nil
end

--[[
entries: the contents in book order, { title, depth, page? }. Returns { index = first back-matter entry,
gray = { indexes of unknown entries between the last chapter and it } } or nil.
opts.min_page: back matter can't start before this page.
]]
function F.findBoundary(entries, opts)
    opts = opts or {}
    local n = #entries
    if n < 2 then return nil end
    -- an entry under a back-matter entry is back matter ("Appendices" > "Cast of Characters")
    local class, stack, top = {}, {}, 0
    for i, e in ipairs(entries) do
        local d = math.max(1, math.floor(tonumber(e.depth) or 1))
        for k = d, top do stack[k] = nil end
        local inherited
        for k = 1, d - 1 do
            if stack[k] == "back" then inherited = "back" end
        end
        class[i] = inherited or F.classify(e.title)
        stack[d], top = class[i] or "?", d
    end
    local index, unknown, stop = nil, 0, 0
    for i = n, 1, -1 do
        local e = entries[i]
        if class[i] == "story" then stop = i break end
        if opts.min_page and e.page and e.page < opts.min_page then stop = i break end
        if class[i] == "back" then
            index, unknown = i, 0
        else
            unknown = unknown + 1
            if unknown > F.MAX_UNKNOWN then stop = i break end
        end
    end
    if not index then return nil end
    local gray = {}
    for i = stop + 1, index - 1 do
        if class[i] == nil then gray[#gray + 1] = i end
    end
    return { index = index, gray = gray, last_story = stop > 0 and class[stop] == "story" and stop or nil }
end

-- In the reader ----------------------------------------------------------------------------------------------

local function storyEnd(ui)
    local se = ui.doc_settings and ui.doc_settings:readSetting("quiet_story_end")
    return type(se) == "table" and se or nil
end

-- First page of the back matter in the current layout, or nil when the story runs to the end.
local function boundaryPage(ui, se)
    se = se or storyEnd(ui)
    if not se or se.how == "none" then return nil end
    local ok, p = pcall(function()
        if se.xpointer and ui.rolling then return ui.document:getPageFromXPointer(se.xpointer) end
        return se.page
    end)
    p = ok and tonumber(p) or nil
    if p and p > 1 then return p end
end
F.boundaryPage = boundaryPage

local function computeStoryEnd(ui)
    if not (ui and ui.document and ui.doc_settings) then return nil end
    pcall(function() ui.toc:fillToc() end)
    local toc = ui.toc and ui.toc.toc or {}
    local pages = ui.document:getPageCount()
    local se = storyEnd(ui)
    if se and se.version == F.VERSION and se.toc_n == #toc then
        -- the share of the book moves with the text size; the place itself doesn't
        local b = boundaryPage(ui, se)
        local pct = b and (b - 1) / pages or nil
        if pct and math.abs((se.pct or 0) - pct) > 0.002 then
            se.pct = pct
            ui.doc_settings:saveSetting("quiet_story_end", se)
        end
        return se, nil
    end
    local entries = {}
    for i, item in ipairs(toc) do
        entries[i] = { title = item.title or "", depth = item.depth or 1, page = item.page, xpointer = item.xpointer }
    end
    local found = F.findBoundary(entries, { min_page = math.floor(pages * F.MIN_SHARE) })
    se = { version = F.VERSION, toc_n = #toc, how = "none" }
    if found then
        local e = entries[found.index]
        se.how, se.title, se.xpointer, se.page = "toc", e.title, e.xpointer, e.page
        se.pct = e.page and (e.page - 1) / pages or nil
    end
    ui.doc_settings:saveSetting("quiet_story_end", se)
    return se, found and { entries = entries, found = found } or nil
end

-- With a Jev key: is one of the unknown entries after the last chapter already past the story?
local ENDINGS = { "epilogue", "afterword", "conclusion", "conclusions", "coda", "postscript", "the end", "finale" }

local function askJev(ui, ctx)
    local found, entries = ctx.found, ctx.entries
    if #found.gray == 0 or #found.gray > 6 or not found.last_story then return end
    -- only after a closing section (an Epilogue, a Conclusion): after a plain chapter, an unknown entry is far
    -- more likely the next chapter's title
    local last = normalize(entries[found.last_story].title)
    local closing = false
    for _, w in ipairs(ENDINGS) do
        if startsWord(last, w) then closing = true end
    end
    if not closing then return end
    local ok, Jev = pcall(require, "quiet_jev")
    if not (ok and type(Jev) == "table" and Jev.available and Jev.available()) then return end
    local options, at = {}, {}
    for _, i in ipairs(found.gray) do
        options[#options + 1] = entries[i].title
        at[#at + 1] = i
    end
    options[#options + 1] = entries[found.index].title
    at[#at + 1] = found.index
    local props = ui.doc_props or {}
    local lines = { string.format("Book: %s%s", props.display_title or props.title or "",
        props.authors and (" by " .. props.authors:gsub("\n", ", ")) or ""), "End of its table of contents:" }
    for i = found.last_story, math.min(#entries, found.index + 3) do lines[#lines + 1] = entries[i].title end
    local question = "Which entry is the first one that is no longer part of the story or main text (a note to "
        .. "readers, acknowledgments, author pages, ads or previews of other books)?"
    pcall(Jev.choice, {
        state = table.concat(lines, "\n"),
        question = question,
        options = options,
        callback = function(res, err)
            if err or type(res) ~= "table" or not ui.document then return end
            local i = tonumber(res.index)
            local p = res.probabilities and res.probabilities[i]
            if not i or i >= #at or (tonumber(p) or 0) < F.JEV_SURE then return end
            local e = entries[at[i]]
            local se = storyEnd(ui)
            if not se or se.toc_n ~= ctx.toc_n then return end
            -- the layout may have changed while Jev thought: find the entry's page in the layout of now
            local pages = ui.document:getPageCount()
            local page = e.page
            if e.xpointer and ui.rolling then
                local okp, p = pcall(function() return ui.document:getPageFromXPointer(e.xpointer) end)
                if okp and tonumber(p) then page = tonumber(p) end
            end
            se.how, se.title, se.xpointer, se.page = "jev", e.title, e.xpointer, page
            se.pct = page and (page - 1) / pages or se.pct
            ui.doc_settings:saveSetting("quiet_story_end", se)
        end,
    })
end

-- "Finished · marked as read  Undo": a small pill above the footer. Undo is the only thing it keeps; any other
-- touch puts it away and goes on to the page (a page turn still turns the page).
local function noteClass()
    local Device = require("device")
    local Event = require("ui/event")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local UIManager = require("ui/uimanager")
    local Q = require("quiet_ui")
    local Screen = Device.screen

    local Note = InputContainer:extend{ on_undo = nil, timeout = 6 }

    function Note:init()
        local px = Q.px
        local W, H = Screen:getWidth(), Screen:getHeight()
        local label = Q.text("Finished \u{00B7} marked as read", 31)
        local undo_text = Q.text("Undo", 31, { bold = true })
        local undo_w = undo_text:getSize().w + px(64)
        local h = px(100)
        local r = math.floor(h / 2)
        local w = px(48) + label:getSize().w + px(12) + undo_w + px(8)
        self.undo = Q.Tap:new{ w = undo_w, h = h - px(12), content = undo_text,
            callback = function() self:doUndo() end }
        local row = HorizontalGroup:new{ align = "center", Q.hspan(48), label, Q.hspan(12), self.undo }
        self.panel = Q.Panel:new{ w = w, h = h, radii = { r, r, r, r }, border = Q.LINE,
            bw = px(3), content = LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, row } }
        self.region = Geom:new{ x = math.floor((W - w) / 2), y = H - h - px(150), w = w, h = h }
        self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
        self[1] = self.panel
        self.close_fn = function() self:dismiss() end
    end

    function Note:getSize() return self.dimen end

    function Note:paintTo(bb, x, y)
        self.panel:paintTo(bb, self.region.x, self.region.y)
    end

    function Note:onShow()
        UIManager:setDirty(self, function() return "ui", self.region end)
        UIManager:scheduleIn(self.timeout, self.close_fn)
        return true
    end

    function Note:dismiss()
        if self.closed then return end
        self.closed = true
        UIManager:unschedule(self.close_fn)
        UIManager:close(self, "ui", self.region)
    end

    function Note:doUndo()
        self:dismiss()
        if self.on_undo then self.on_undo() end
    end

    function Note:onGesture(ges)
        if ges.ges == "touch" then return true end
        self:dismiss()
        UIManager:nextTick(function() UIManager:sendEvent(Event:new("Gesture", ges)) end)
        return true
    end

    function Note:onCloseWidget()
        UIManager:unschedule(self.close_fn)
    end

    return Note
end

local function markFinished(ui, silent)
    local ds = ui.doc_settings
    local summary = ds:readSetting("summary") or {}
    if summary.status == "complete" then return end
    local before = { status = summary.status, modified = summary.modified }
    if ui.status and ui.status.markBook then
        ui.status:markBook(true)
    else
        summary.status, summary.modified = "complete", os.date("%Y-%m-%d")
        ds:saveSetting("summary", summary)
        require("ui/widget/booklist").setBookInfoCacheProperty(ui.document.file, "status", "complete")
    end
    ds:saveSetting("quiet_finished_at", os.time())
    pcall(ds.flush, ds)
    require("logger").info("quiet finish: marked finished", ui.document and ui.document.file)
    if silent then return end
    local undo = function()
        if not ui.document then return end
        local s = ds:readSetting("summary") or {}
        s.status = before.status or "reading"
        s.modified = before.modified or os.date("%Y-%m-%d")
        ds:saveSetting("summary", s)
        ds:saveSetting("quiet_finish_declined", true)
        ds:delSetting("quiet_finished_at")
        require("ui/widget/booklist").setBookInfoCacheProperty(ui.document.file, "status", s.status)
        pcall(ds.flush, ds)
    end
    local ok, err = pcall(function()
        local note = noteClass():new{ on_undo = undo }
        ui._quiet_finish_note = note
        require("ui/uimanager"):show(note, "ui", note.region)
    end)
    if not ok then require("logger").warn("quiet finish: no notice:", err) end
end
F.markFinished = markFinished

-- At least F.COVERAGE of the story's pages read: the visits KOReader's statistics has (saved and in memory), the
-- pages read in this session (session: { page, tp }, tp = the page count of the layout each was read in, so a
-- text-size change rescales them like statistics' own rows; they cover what statistics missed while switched off
-- or not installed), and the page being left (also_page, in the current layout: statistics records it only after
-- this runs, since plugins see PageUpdate and CloseDocument in load order and this one loads first). A short run
-- of turns near the end never covers half a story.
local function readEnough(ui, last_story_page, session, also_page)
    if not last_story_page or last_story_page <= 0 then return false end
    local ok, RT = pcall(require, "quiet_readtime")
    if not ok then return false end
    local also = {}
    if also_page then also[1] = { page = also_page } end
    for _, v in ipairs(session or {}) do also[#also + 1] = v end
    local info = RT.forUI(ui, { upto = last_story_page, also = also })
    return info and info.pages_read_upto and info.pages_read_upto / last_story_page >= F.COVERAGE or false
end
F.readEnough = readEnough

function F.attach(ui)
    if not ui or ui.quietfinish then return end
    local UIManager = require("ui/uimanager")
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local logger = require("logger")

    local Watcher = WidgetContainer:extend{}

    -- (PDFs and other paging documents have no getCurrentPage: quiet_readtime knows where they keep it)
    function Watcher:pageNow()
        return self.ui.document and require("quiet_readtime").currentPage(self.ui)
    end

    function Watcher:pages()
        return self.ui.document and self.ui.document:getPageCount()
    end

    -- arrived: how the reader came to the current page (turn, jump or open), when, and in which layout (its page
    -- count): KOReader updates the page count before a re-render's PageUpdate, so the page being left must keep
    -- the count it was read in.
    function Watcher:onReaderReady()
        self.page = self:pageNow()
        self.arrived = { kind = "open", at = os.time(), tp = self:pages() }
        self.read, self.read_keys = {}, {}
        self.compute_fn = self.compute_fn or function()
            local ok, se, ctx = pcall(computeStoryEnd, self.ui)
            if not ok then
                logger.warn("quiet finish: no story end:", se)
                return
            end
            if ctx then
                ctx.toc_n = se and se.toc_n
                askJev(self.ui, ctx)
            end
        end
        -- after the book is on screen: opening stays as fast as it was
        UIManager:scheduleIn(2, self.compute_fn)
    end

    function Watcher:tryMark(last_story_page, silent, also_page)
        local ds = self.ui.doc_settings
        local summary = ds:readSetting("summary") or {}
        if summary.status == "complete" or ds:readSetting("quiet_finish_declined") then return end
        if not readEnough(self.ui, last_story_page, self.read, also_page) then return end
        markFinished(self.ui, silent)
    end

    -- A page counts as read in this session when you stayed on it for F.MIN_DWELL awake, however you got there
    -- (statistics counts that visit too; only the finishing turn itself must follow a turn); kept with the page
    -- count of the layout it was read in (the arrival's).
    function Watcher:noteRead(page, came, dwell)
        if not page or dwell < F.MIN_DWELL then return end
        local tp = came.tp
        local key = page .. ":" .. tostring(tp)
        if self.read_keys[key] then return end
        self.read_keys[key] = true
        self.read[#self.read + 1] = { page = page, tp = tp }
    end

    -- Time asleep (the screensaver) or with reading paused isn't time on the page: like statistics, which moves
    -- its current visit's start by the pause, the arrival moves forward by it. These return nothing, so the events
    -- go on to statistics.
    function Watcher:settlePause(now)
        if self.paused_at and self.arrived then
            self.arrived.at = self.arrived.at + math.max(0, now - self.paused_at)
        end
        if self.paused_at then self.paused_at = now end
    end
    function Watcher:onReadingPaused() self.paused_at = self.paused_at or os.time() end
    function Watcher:onReadingResumed()
        self:settlePause(os.time())
        self.paused_at = nil
    end
    function Watcher:onSuspend() self:onReadingPaused() end
    function Watcher:onResume() self:onReadingResumed() end

    function Watcher:onPageUpdate(page)
        page = tonumber(page)
        if not page or not self.arrived then return end
        self:settlePause(os.time())
        local pages_now = self:pages()
        -- a re-render can leave the page number as it was: it's still a new place in a new layout
        local relaid = pages_now ~= self.arrived.tp
        if page == self.page and not relaid then return end
        local now = os.time()
        local prev, came = self.page, self.arrived
        local dwell = now - came.at
        self:noteRead(prev, came, dwell)
        -- any forward move through the page-turn entry point is a turn, however many hidden pages it skips; a
        -- re-render never is
        local kind = (self.turning and not relaid and prev and page > prev) and "turn" or "jump"
        self.page, self.arrived = page, { kind = kind, at = now, tp = pages_now }
        if kind ~= "turn" then return end
        local b = boundaryPage(self.ui)
        if b and prev < b and page >= b and dwell >= F.MIN_DWELL and (came.kind == "turn" or came.kind == "open") then
            self:tryMark(b - 1, false, prev)
        end
    end

    -- Where you are and where the story ends, both in pages of the layout of now, for quiet_readtime's closed-book
    -- figures: KOReader's own saved percent counts within the main flow when non-linear fragments are hidden, and
    -- quiet_story_end.pct is from the layout it was worked out in. Saved with KOReader's settings, and on close
    -- too: a normal close clears the document before SaveSettings.
    function Watcher:savePosition()
        local doc, ds = self.ui.document, self.ui.doc_settings
        if not (doc and ds) then return end
        ds:saveSetting("quiet_position", { page = require("quiet_readtime").currentPage(self.ui),
            pages = doc:getPageCount(), story_end = boundaryPage(self.ui) })
    end
    function Watcher:onSaveSettings() self:savePosition() end

    -- Scroll mode moves with PosUpdate (statistics follows it the same way).
    function Watcher:onPosUpdate(_, page)
        if type(page) == "number" then return self:onPageUpdate(page) end
    end

    -- Read the last page of the story and closed the book there: finished too (no notice, the book is closing).
    function Watcher:onCloseDocument()
        if self.compute_fn then UIManager:unschedule(self.compute_fn) end
        local note = self.ui._quiet_finish_note
        if note and not note.closed then note:dismiss() end
        local okp, errp = pcall(self.savePosition, self)
        if not okp then logger.warn("quiet finish: position not saved:", errp) end
        local doc = self.ui.document
        if not (doc and self.arrived) then return end
        self:settlePause(os.time())
        local b = boundaryPage(self.ui)
        local last = b and b - 1 or doc:getPageCount()
        local now_page = require("quiet_readtime").currentPage(self.ui)
        if self.page == last and now_page == last and self.arrived.kind == "turn"
                and os.time() - self.arrived.at >= F.MIN_DWELL then
            local ok, err = pcall(self.tryMark, self, last, true, self.page)
            if not ok then logger.warn("quiet finish:", err) end
        end
    end

    local w = Watcher:new{ ui = ui, read = {}, read_keys = {} }
    -- A page turn goes through GotoViewRel; a jump (contents, links, the keypad, search, the scrubber) goes through
    -- GotoPage, GotoXPointer, GotoPercent… and both emit the same PageUpdate, a jump to the next page included. So
    -- the turn entry point says so while it runs (it emits PageUpdate synchronously, before returning).
    local function turned(ok, ...)
        w.turning = false
        if not ok then error((...), 0) end
        return ...
    end
    for _, mod in ipairs({ ui.rolling or false, ui.paging or false }) do
        local orig = mod and mod.onGotoViewRel
        if type(orig) == "function" then
            mod.onGotoViewRel = function(this, ...)
                w.turning = true
                return turned(pcall(orig, this, ...))
            end
        end
    end
    ui:registerModule("quietfinish", w)
end

-- For bin/kcmd: where the story ends in the open book, and what would happen.
function F.debug(ui)
    ui = ui or require("apps/reader/readerui").instance
    if not ui then return "no book open" end
    local se = storyEnd(ui)
    local b = boundaryPage(ui, se)
    local pages = ui.document:getPageCount()
    local ok, RT = pcall(require, "quiet_readtime")
    local info = ok and RT.forUI(ui, { upto = b and b - 1 or pages }) or {}
    return string.format("story end: %s (%s, page %s of %d, %.1f%%) | now page %d | read %s of %s story pages | "
        .. "status %s%s", se and (se.title or "end of book") or "not yet worked out", se and se.how or "-",
        tostring(b), pages, b and (b - 1) / pages * 100 or 100, ok and RT.currentPage(ui) or -1,
        tostring(info.pages_read_upto), tostring(b and b - 1 or pages),
        tostring((ui.doc_settings:readSetting("summary") or {}).status),
        ui.doc_settings:readSetting("quiet_finish_declined") and ", declined" or "")
end

return F
