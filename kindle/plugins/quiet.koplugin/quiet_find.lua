--[[
Finding things in the book for Search & Ask (quiet_ask.lua), without the network.

  - route(query): what someone typed is a place to go ("120", "40%"), words to find ("irrational lab"), a question
    for Claude ("Why did she leave Google?"), or, from four words up without a question word, a moment described
    in words ("the bit where she quits"), which Jev settles when it's there.
  - offers(query, ctx): "Go to page 120", "Go to 40%", a chapter whose title matches.
  - run(ui, term, done): every match in the book, ignoring capitals and accents (crengine's own find-all with the
    flags of KOReader's "Ignore diacritics and accents"; for PDF and DjVu our own folded matcher, pagedHits), in a
    background process so typing never waits on it.
  - keywords / term: the words of a question worth finding ("Google" from "Why did she leave Google?").
  - paragraphs / rank: passages from the text, scored by shared words (BM25), best first: the candidates Jev
    chooses from, or the best match when Jev isn't there.
  - citations(answer): the pages Claude cites as "(p 12)" or "(p 15–16)", for the page chips.

Everything except run() is plain Lua with no KOReader dependency (pagedHits uses KOReader's lowercasing when it's
there; tests: scratchpad/tests/a1/test_find.lua).
]]

local Find = {}

Find.MAX_HITS = 1000      -- matches kept from one search; the count above that shows as "1000+"
Find.CONTEXT_WORDS = 8    -- words of context on each side of a match
Find.SEARCH_FLAGS = 0x01FF -- crengine: across text nodes, folded spaces/apostrophes/hyphens, ignore diacritics

-- Accented Latin letters, typographic quotes and dashes, folded to plain lower-case ASCII.
local FOLD = {}
do
    local groups = {
        a = "ÀÁÂÃÄÅàáâãäåĀāĂăĄą", c = "ÇçĆćĈĉĊċČč", d = "ÐðĎďĐđ", e = "ÈÉÊËèéêëĒēĔĕĖėĘęĚě",
        g = "ĜĝĞğĠġĢģ", h = "ĤĥĦħ", i = "ÌÍÎÏìíîïĨĩĪīĬĭĮįİı", j = "Ĵĵ", k = "Ķķ", l = "ĹĺĻļĽľĿŀŁł",
        n = "ÑñŃńŅņŇň", o = "ÒÓÔÕÖØòóôõöøŌōŎŏŐő", r = "ŔŕŖŗŘř", s = "ŚśŜŝŞşŠš", t = "ŢţŤťŦŧ",
        u = "ÙÚÛÜùúûüŨũŪūŬŭŮůŰűŲų", w = "Ŵŵ", y = "ÝýÿŶŷŸ", z = "ŹźŻżŽž",
        ae = "Ææ", oe = "Œœ", ss = "ß", th = "Þþ",
        ["'"] = "‘’‚‛′", ['"'] = "“”„‟″«»", ["-"] = "‐‑‒–—―", [" "] = "\u{00A0}\u{2009}\u{202F}",
    }
    for plain, chars in pairs(groups) do
        for ch in chars:gmatch("[\192-\244][\128-\191]*") do FOLD[ch] = plain end
    end
end

function Find.fold(s)
    if not s then return "" end
    return (s:gsub("[\192-\244][\128-\191]*", FOLD):lower())
end

local STOP = {}
for w in ([[a about above after again against all am an and any are as at be because been before being below
    between both but by can cannot could did do does doing down during each few for from further had has have
    having he her here hers herself him himself his how i if in into is it its itself just me more most my myself
    no nor not now of off on once only or other ought our ours ourselves out over own same she should so some
    such than that the their theirs them themselves then there these they this those through to too under until
    up very was we were what when where which while who whom whose why will with would you your yours yourself
    yourselves s t d ll m re ve also us get got really thing things one ones much many like]]):gmatch("%S+") do
    STOP[w] = true
end

-- Words that make what was typed a question or a request for Claude.
local ASK_FIRST = {}
for w in ([[who whom whose what whats why how when where which is are was were do does did can could should
    would will has have had explain explains summarize summarise summary recap tell describe compare define
    meaning translate list give remind clarify analyse analyze outline]]):gmatch("%S+") do
    ASK_FIRST[w] = true
end
-- These alone are already a request ("recap", "summary").
local ASK_ALONE = { explain = true, summarize = true, summarise = true, summary = true, recap = true, outline = true }
-- Words that only frame a question; never worth finding.
local FRAMING = {}
for w in ([[explain explains summarize summarise summary recap tell describe compare define meaning mean means
    translate list give remind clarify analyse analyze outline happen happened happens happening think say says
    said book page pages chapter chapters story author far point part bit going]]):gmatch("%S+") do
    FRAMING[w] = true
end

local function words(s)
    local out = {}
    for w in s:gmatch("[^%s]+") do out[#out + 1] = w end
    return out
end

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end
Find.trim = trim

-- Starts with a capital: ASCII, or Latin-1 À–Þ.
local function isCap(w)
    local b1, b2 = w:byte(1, 2)
    if not b1 then return false end
    if b1 >= 65 and b1 <= 90 then return true end
    return b1 == 195 and b2 ~= nil and b2 >= 128 and b2 <= 158
end

local function cleanWord(w)
    return (w:gsub("^'+", ""):gsub("'s$", ""):gsub("'+$", ""))
end

-- A place to go: { kind = "page", page = n } or { kind = "percent", percent = p }, or nil.
function Find.place(query)
    local q = Find.fold(trim(query))
    local n = q:match("^(%d+)$") or q:match("^p%.?%s*(%d+)$") or q:match("^pg%.?%s*(%d+)$") or q:match("^page%s+(%d+)$")
    if n then return { kind = "page", page = tonumber(n) } end
    local p = q:match("^(%d+%.?%d*)%s*%%$") or q:match("^(%d+%.?%d*)%s*percent$")
    if p then return { kind = "percent", percent = tonumber(p) } end
    return nil
end

--[[ What kind of input this is:
  "goto"      a page number or a percentage (still also searched, for "1984")
  "ask"       a question or a request for Claude
  "find"      one to three plain words
  "moment"    four or more words without a question word: a passage described in words (Jev may turn it into
              "ask" or "find")
]]
function Find.route(query)
    local q = trim(query)
    if q == "" then return nil end
    if Find.place(q) then return "goto" end
    local folded = Find.fold(q)
    if folded:find("%?%s*$") then return "ask" end
    if folded:find("who'?s who") then return "ask" end
    local w = words(folded)
    local first = (w[1] or ""):gsub("[^%w']", ""):gsub("'s$", "")
    if #w == 1 and ASK_ALONE[first] then return "ask" end
    local orig = words(q)
    local name = #orig == 2 and isCap(orig[1]) and isCap(orig[2]) -- "Will Smith"
    if #w >= 2 and ASK_FIRST[first] and not name then return "ask" end
    if #w <= 3 then return "find" end
    return "moment"
end

-- Salient words of a query, best first: names (capitalised, not first word) before long words before the rest.
-- Two adjacent capitalised words stay together ("Dan Ariely").
-- Titles before a name: the name is what to look for ("Mr. Darcy" is "Mr. Darcy" in the book, so "Mr Darcy", with the
-- full stop taken out of the question, would find nothing). Only before a name: "the Lord" stays (review C8-9).
local TITLES = {}
for _, t in ipairs({ "mr", "mrs", "ms", "miss", "dr", "sir", "lady", "lord", "st", "prof", "capt", "col", "rev" }) do
    TITLES[t] = true
end

function Find.keywords(query)
    local q = trim(query):gsub("‘", "'"):gsub("’", "'"):gsub("“", " "):gsub("”", " "):gsub("[%?%!%.,;:\"()%[%]]", " ")
    local raw = words(q)
    local cands, seen = {}, {}
    local i = 1
    while i <= #raw do
        local w = cleanWord(raw[i])
        local f = Find.fold(w)
        local cap = i > 1 and isCap(w)
        -- a title is a name's title when the word after it would itself be kept as a search word, whatever the case
        -- ("mr. darcy" too; review C8-9, rounds 2 and 3); otherwise it is the subject ("the Lord", "What did the
        -- Lord say?", "Lord of ...")
        local next_word = raw[i + 1] and cleanWord(raw[i + 1])
        local next_f = next_word and Find.fold(next_word) or ""
        local title = TITLES[f] and #next_f >= 2 and not STOP[next_f] and not FRAMING[next_f] and not ASK_FIRST[next_f]
        if f ~= "" and not STOP[f] and not FRAMING[f] and not ASK_FIRST[f] and not title and #f >= 2 then
            local term, score = w, (#f >= 6 and 1 or 0) + (cap and 3 or 0)
            local nxt = raw[i + 1] and cleanWord(raw[i + 1])
            if cap and nxt and isCap(nxt) and not STOP[Find.fold(nxt)] then
                term, score, i = w .. " " .. nxt, score + 2, i + 1
            end
            local key = Find.fold(term)
            if not seen[key] then
                seen[key] = true
                cands[#cands + 1] = { term = term, score = score, order = #cands }
            end
        end
        i = i + 1
    end
    table.sort(cands, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.order < b.order
    end)
    local out = {}
    for _, c in ipairs(cands) do out[#out + 1] = c.term end
    return out
end

-- What to look for in the text: the whole query when finding words, else its best keyword.
function Find.term(query, kind)
    local q = trim(query)
    if kind == "find" or kind == "goto" then return q end
    return Find.keywords(q)[1]
end

-- "Go to" offers for what was typed so far (cheap: runs on every keystroke).
-- ctx = { total = page count, toc = { {title=, page=, xpointer=, depth=} … } }
function Find.offers(query, ctx)
    local out = {}
    local q = trim(query)
    if q == "" then return out end
    local place = Find.place(q)
    if place and place.kind == "page" and place.page >= 1 and place.page <= (ctx.total or 0) then
        out[#out + 1] = { kind = "page", page = place.page, label = "Go to page " .. place.page }
    elseif place and place.kind == "percent" and place.percent >= 0 and place.percent <= 100 then
        local pct = math.floor(place.percent * 10 + 0.5) / 10
        out[#out + 1] = { kind = "percent", percent = pct,
            label = "Go to " .. (pct == math.floor(pct) and string.format("%d", pct) or tostring(pct)) .. "%" }
    end
    local fq = Find.fold(q):gsub("^chapter%s+", "chapter "):gsub("^ch%.?%s+", "chapter ")
    if #fq >= 3 and not fq:match("^%d+$") and ctx.toc then
        local best = {}
        for _, e in ipairs(ctx.toc) do
            local ft = Find.fold(e.title or ""):gsub("%s+", " ")
            local score = 0
            if ft == fq then score = 3
            elseif ft:find(fq, 1, true) == 1 then score = 2.5
            elseif #fq >= 4 and ft:find(fq, 1, true) then score = 2
            else
                -- most of the typed words appear in the title
                local tw, hit = 0, 0
                for w in fq:gmatch("%w+") do
                    if not STOP[w] then
                        tw = tw + 1
                        if ft:find("%f[%w]" .. w:gsub("%p", "%%%0") .. "%f[%W]") then hit = hit + 1 end
                    end
                end
                if tw >= 2 and hit / tw >= 0.75 then score = 1 + hit / tw end
            end
            if score > 0 then best[#best + 1] = { e = e, score = score } end
        end
        table.sort(best, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return (a.e.page or 0) < (b.e.page or 0)
        end)
        for k = 1, math.min(2, #best) do
            local e = best[k].e
            local title = trim((e.title or ""):gsub("%s+", " "))
            if #title > 40 then title = title:sub(1, 38):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "…" end
            out[#out + 1] = { kind = "chapter", page = e.page, xpointer = e.xpointer, label = "Go to “" .. title .. "”" }
        end
    end
    return out
end

-- Passages to rank: each page's text split into paragraphs; very short lines (headings) dropped, long ones
-- cut into ~500-character pieces at sentence ends. pages[n] = text of page n.
function Find.paragraphs(pages, from, to)
    local out = {}
    for p = from, to do
        local text = pages[p]
        if text then
            for para in (text .. "\n"):gmatch("([^\n]*)\n") do
                para = trim(para:gsub("%s+", " "))
                if #para >= 60 then
                    while #para > 700 do
                        local cut = para:find("[%.%!%?]%S*%s", 420) or para:find("%s", 520) or 560
                        out[#out + 1] = { text = para:sub(1, cut), page = p }
                        para = trim(para:sub(cut + 1))
                    end
                    if #para >= 60 then out[#out + 1] = { text = para, page = p } end
                end
            end
        end
    end
    return out
end

local function stem(w)
    w = w:gsub("'s$", ""):gsub("'$", "")
    if #w > 5 and w:sub(-3) == "ing" then return w:sub(1, -4) end
    if #w > 4 and w:sub(-2) == "ed" then return w:sub(1, -3) end
    if #w > 4 and w:sub(-2) == "es" then return w:sub(1, -3) end
    if #w > 3 and w:sub(-1) == "s" and w:sub(-2) ~= "ss" then return w:sub(1, -2) end
    return w
end

function Find.tokens(s)
    local out = {}
    for w in Find.fold(s):gmatch("[%w'\128-\255]+") do
        if not STOP[w] and #w >= 2 then out[#out + 1] = stem(w) end
    end
    return out
end

-- BM25 over the passages for the query's words; returns up to `limit` passages, best first, each with .score.
-- Passages sharing no word with the query are left out.
function Find.rank(paras, query, limit)
    local qt = {}
    for _, t in ipairs(Find.tokens(query)) do
        if not FRAMING[t] then qt[t] = true end
    end
    if not next(qt) then return {} end
    local df, docs, total_len = {}, {}, 0
    for i, p in ipairs(paras) do
        local tf, len = {}, 0
        for _, t in ipairs(Find.tokens(p.text)) do
            len = len + 1
            if qt[t] then tf[t] = (tf[t] or 0) + 1 end
        end
        for t in pairs(tf) do df[t] = (df[t] or 0) + 1 end
        docs[i] = { tf = tf, len = len }
        total_len = total_len + len
    end
    local n = #paras
    if n == 0 then return {} end
    local avg = total_len / n
    local k1, b = 1.2, 0.75
    local scored = {}
    for i, d in ipairs(docs) do
        local s = 0
        for t, f in pairs(d.tf) do
            local idf = math.log(1 + (n - df[t] + 0.5) / (df[t] + 0.5))
            s = s + idf * f * (k1 + 1) / (f + k1 * (1 - b + b * d.len / math.max(avg, 1)))
        end
        if s > 0 then scored[#scored + 1] = { text = paras[i].text, page = paras[i].page, score = s, i = i } end
    end
    table.sort(scored, function(x, y)
        if x.score ~= y.score then return x.score > y.score end
        return x.i < y.i
    end)
    local out = {}
    for k = 1, math.min(limit or 40, #scored) do out[k] = scored[k] end
    return out
end

--[[ Pages cited in an answer, in order of first mention: { {from=12, to=12}, {from=15, to=16} }.
Understands (p 12), (p. 12), (pp 15–16), (pages 15-16), (p 12, 15), [p 12], "(see p 12)". Pages outside 1..total
are dropped. ]]
function Find.citations(text, total)
    local out, seen = {}, {}
    if not text then return out end
    local s = text:gsub("\u{2013}", "-"):gsub("\u{2014}", "-"):gsub("\u{00A0}", " ")
    local function add(a, b)
        a, b = tonumber(a), tonumber(b or a)
        if not a or not b then return end
        if b < a then a, b = b, a end
        if a < 1 or (total and b > total) or b - a > 50 then return end
        local key = a .. "-" .. b
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = { from = a, to = b }
        end
    end
    for group in s:gmatch("[%(%[]([^%)%]]*)[%)%]]") do
        local g = group:lower()
        local body = g:match("^%s*see%s+(.*)$") or g
        local list = body:match("^%s*pp?%.?%s*([%d%s,%-and]+)$") or body:match("^%s*pages?%s+([%d%s,%-and]+)$")
        if list then
            for item in (list:gsub("and", ",") .. ","):gmatch("([^,]+),") do
                local a, b = item:match("(%d+)%s*%-%s*(%d+)")
                if a then add(a, b) else
                    local single = item:match("(%d+)")
                    if single then add(single) end
                end
            end
        else
            -- a page mentioned inside other words: "(Dan Ariely, p 9)"
            local pos = 1
            while true do
                local st, en, a = g:find("%f[%a]pp?%.?%s*(%d+)", pos)
                if not st then break end
                add(a, g:match("^%s*%-%s*(%d+)", en + 1))
                pos = en + 1
            end
        end
    end
    return out
end

function Find.citationLabel(c)
    if c.from == c.to then return "p " .. c.from end
    return "p " .. c.from .. "–" .. c.to
end

--[[ Every match in a paged document's text layer (PDF, DjVu), ignoring capitals and accents as in other books
(review C4-CF-2: KoptInterface's own find-all only lowercases, so "cafe" never found "café"). Its way of matching
stays: the words typed against consecutive words of the page, the first may be the end of a word, the last the
start of one, those between are whole words, and a word with Chinese, Japanese or Korean in it goes character by
character, split before anything is folded (review C4-CR2-1: "１２" folds to "12" but stays two pieces). Here that
is a plain find in the page's words joined by spaces, both sides lowercased as KOReader does (utf8proc, any script),
then folded (Find.fold). The words around a match stay on its page. Runs in the background task. ]]
-- util.isCJKChar's blocks, near enough, for when KOReader's util isn't loaded
local CJK = {
    "\225[\132-\135][\128-\191]", "\226[\186-\191][\128-\191]", "[\227-\237][\128-\191][\128-\191]",
    "\239[\164-\171][\128-\191]", "\239\184[\176-\191]", "\239\185[\128-\143]", "\239[\188-\191][\128-\191]",
    "\240[\160-\178][\128-\191][\128-\191]",
}
function Find.pagedHits(doc, pattern, max_hits)
    local lower = function(s) return s end
    local hasCJK = function(s)
        for _, pat in ipairs(CJK) do if s:find(pat) then return true end end
        return false
    end
    local ok_t, util = pcall(require, "util")
    local ok_u, Utf8Proc = pcall(require, "ffi/utf8proc")
    if ok_t and type(util) == "table" then
        hasCJK = util.hasCJKChar or hasCJK
        if ok_u and type(Utf8Proc) == "table" and Utf8Proc.lowercase and util.fixUtf8 then
            lower = function(s) return Utf8Proc.lowercase(util.fixUtf8(s, "?")) end
        end
    end
    local function norm(s) return Find.fold(lower(s)) end
    local plist = {}
    local function piece(raw)
        local f = norm(raw)
        if f ~= "" then plist[#plist + 1] = f end
    end
    for word in pattern:gmatch("%S+") do
        if hasCJK(word) then
            local run = ""
            for ch in word:gmatch("[%z\1-\127\192-\255][\128-\191]*") do
                if #ch > 1 then
                    if run ~= "" then piece(run) end
                    run = ""
                    piece(ch)
                else
                    run = run .. ch
                end
            end
            if run ~= "" then piece(run) end
        else
            piece(word)
        end
    end
    local fpat = table.concat(plist, " ")
    local hits = {}
    if fpat == "" then return hits end
    for page = 1, doc:getPageCount() do
        local ok, lines = pcall(function()
            if doc.getPageTextBoxes then return doc:getPageTextBoxes(page) end
            return doc:getPageText(page)
        end)
        local words = {}
        if ok and type(lines) == "table" then
            for _, line in ipairs(lines) do
                for _, box in ipairs(type(line) == "table" and line or {}) do
                    if type(box) == "table" and type(box.word) == "string" and box.word ~= "" then words[#words + 1] = box.word end
                end
            end
        end
        if #words > 0 then
            local folded, starts, pos = {}, {}, 1
            for i, w in ipairs(words) do
                folded[i], starts[i] = norm(w), pos
                pos = pos + #folded[i] + 1
            end
            local text = table.concat(folded, " ")
            local function wordAt(byte)
                local lo, hi = 1, #starts
                while lo < hi do
                    local mid = math.floor((lo + hi + 1) / 2)
                    if starts[mid] <= byte then lo = mid else hi = mid - 1 end
                end
                return lo
            end
            local from = 1
            while true do
                local a_byte, b_byte = text:find(fpat, from, true)
                if not a_byte then break end
                local a, b = wordAt(a_byte), wordAt(b_byte)
                hits[#hits + 1] = { page = page, start = page, ["end"] = page,
                    prev = table.concat(words, " ", math.max(1, a - Find.CONTEXT_WORDS), a - 1),
                    match = table.concat(words, " ", a, b),
                    next = table.concat(words, " ", b + 1, math.min(#words, b + Find.CONTEXT_WORDS)) }
                if #hits >= max_hits then return hits end
                -- the next match starts in a later word (one per word, as KoptInterface)
                if a >= #words then break end
                from = starts[a + 1]
            end
        end
    end
    return hits
end

-- The text after a match cut where the reader's page ends: as much of next_text as the page's own text from the
-- same point (`tail`) has too, by characters (a book without spaces between words counts the same), any run of
-- spaces and line breaks counting as one space, never half a character.
function Find.clipNext(next_text, tail)
    if not next_text or next_text == "" or type(tail) ~= "string" then return next_text end
    local a, b = next_text:gsub("%s+", " "), tail:gsub("%s+", " ")
    local n = 0
    while n < #b and n < #a and a:byte(n + 1) == b:byte(n + 1) do n = n + 1 end
    if n == #a then return next_text end
    while n > 0 do
        local c = a:byte(n + 1)
        if c < 0x80 or c >= 0xC0 then break end
        n = n - 1
    end
    return (a:sub(1, n):gsub("%s+$", ""))
end

Find.NEAR_PAGES = 2 -- matches this many pages before the reader's are checked too (short pages in between)

-- next_here (review C4-CF-1): crengine's text after a match starts where its word ends (matched_word_suffix_end
-- when the match ends inside one) and runs on regardless of pages. For a match on the reader's page or just before
-- it, what may show with What's ahead off is as much of it as comes before the next page (`limit`, its first
-- xpointer): none when that can't be told or the word itself runs past it; nil when it's all of it, and for
-- matches further away or past the page (hidden then anyway).
local function nextBefore(doc, item, page, reader_page, limit)
    if limit == nil or type(page) ~= "number" or page > reader_page or page < reader_page - Find.NEAR_PAGES then
        return nil
    end
    local here = ""
    local from = item.matched_word_suffix_end or item["end"]
    local ok_e, end_page = pcall(doc.getPageFromXPointer, doc, from)
    -- (crengine gives a range that ends where it starts one character: nothing is left there)
    if limit and from and from ~= limit and ok_e and (end_page or page) <= reader_page then
        local ok, tail = pcall(doc.getTextFromXPointers, doc, from, limit, false)
        if ok and type(tail) == "string" then here = Find.clipNext(item.next_text, tail) end
    end
    if here == (item.next_text or "") then return nil end
    return here
end

--[[ Every match of `term` in the document, in book order, in a background process.
done(hits, err) with hits = { {page=, prev=, match=, next=, next_here=, start=, ["end"]=} … } and hits.capped = true
when MAX_HITS was reached. Returns a job with :cancel(). ]]
function Find.run(ui, term, done)
    local BookCtx = require("quiet_bookctx")
    local doc = ui.document
    local rolling = ui.rolling ~= nil
    local pattern = term
    local ok_u, Utf8Proc = pcall(require, "ffi/utf8proc")
    if ok_u and Utf8Proc.normalize_NFC then pattern = Utf8Proc.normalize_NFC(term) end
    -- the reader's page: the sheet covers it while these results show (a jump closes the sheet)
    local reader_page = rolling and BookCtx.currentPage(ui)
    return BookCtx.runAsync(function()
        if not rolling then return Find.pagedHits(doc, pattern, Find.MAX_HITS) end
        local res = doc:findAllText(pattern, true, Find.CONTEXT_WORDS, Find.MAX_HITS, false, Find.SEARCH_FLAGS)
        -- where the page after the reader's starts (none on the last page; false when it can't be told)
        local limit
        if type(reader_page) == "number" and reader_page < doc:getPageCount() then
            local ok, xp = pcall(doc.getPageXPointer, doc, reader_page + 1)
            limit = ok and type(xp) == "string" and xp ~= "" and xp or false
        end
        local hits = {}
        for i, item in ipairs(res or {}) do
            local page = doc:getPageFromXPointer(item.start)
            hits[i] = { page = page, prev = item.prev_text, next = item.next_text,
                next_here = nextBefore(doc, item, page, reader_page, limit),
                -- the whole word, as KOReader shows it (and as PDFs match)
                match = (item.matched_word_prefix or "") .. (item.matched_text or "") .. (item.matched_word_suffix or ""),
                start = item.start, ["end"] = item["end"] }
        end
        return hits
    end, function(hits, err)
        if hits then hits.capped = #hits >= Find.MAX_HITS end
        done(hits, err)
    end)
end

return Find
