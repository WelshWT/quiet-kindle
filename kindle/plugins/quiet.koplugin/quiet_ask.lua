--[[
Search & Ask: one field to find anything in the book or ask about it (design: "Search & Ask" in docs/design.md).

  local Ask = require("quiet_ask")
  Ask.show(plugin, ui, opts)  -- opens the sheet; returns it
      opts.focus_text   selected text: the question is about that passage (selection bar's Ask Claude)
      opts.focus_page   page of the selection (defaults to the current page)
      opts.query        text to run straight away
      opts.suggest      run a suggestion straight away: "explain_page", "just_happened", "whos_who", "recap",
                        "explain_this", "meaning_here" (the More sheet's old Claude chips map to these)
      opts.keyboard     start with the keyboard up (default: up unless one of the above is given)
      opts.on_close     called once when the sheet closes (the selection bar clears its selection then)
  Ask.SUGGESTIONS             -- { page = {…}, selection = {…} }: id + label of each suggestion

  - Typing: "120" or "40%" offers "Go to page 120" / "Go to 40%" straight away; a chapter title offers that chapter.
    While the keyboard is up the sheet keeps its height and only the part under the field is redrawn, so the field
    never moves and its text never waits behind a suggestion's e-ink update.
  - Go: matching words (capitals and accents ignored) in a background process; a question goes to Claude
    (quiet_claude.lua) with what's been read so far (quiet_bookctx.lua) and its pages come back as links; four
    words or more without a question word find the passage they describe (shared words, then Jev if it's set up).
  - One switch, "What's ahead", off by default: when off, matches past the page stay hidden (with a count), the
    words shown after a match stop where the reader's page does, and Claude reads nothing past the page.
  - Claude's model and effort: the quiet line at the bottom ("Opus 5.5 · High"), tap to change, remembered.
  - Answers stream in, refreshed at most once a second (e-ink); results page with ‹ › or a sideways swipe. One
    that stops part-way keeps what arrived (and offers Try again); one that ran out of room says so (and Go on).
  - Closing the sheet (tap the page above it, swipe it down) stops anything still running.
Settings: quiet_ask_ahead, quiet_ask_recent (last 5), quiet_ask_model, quiet_ask_effort.
]]

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputText = require("ui/widget/inputtext")
local LeftContainer = require("ui/widget/container/leftcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local BookCtx = require("quiet_bookctx")
local Find = require("quiet_find")
local Q = require("quiet_ui")
local Sheet = require("quiet_sheet")
local Screen = Device.screen

local TOP_GAP = 150     -- the page stays visible above the tallest sheet: tap it to close
local FIELD_H = 104
local SWITCH_ROW_H = 72
local CHIP_H = 80
local REFRESH_EVERY = 1 -- s, while an answer streams in
local RECENT_MAX = 5

local SUGGESTIONS = {
    page = {
        { id = "explain_page", label = "Explain this page" },
        { id = "just_happened", label = "What just happened?" },
        { id = "whos_who", label = "Who's who so far" },
        { id = "recap", label = "Recap so far" },
    },
    selection = {
        { id = "explain_this", label = "Explain this" },
        { id = "meaning_here", label = "What does this mean here?" },
        { id = "recap", label = "Recap so far" },
    },
}

local PROMPTS = {
    explain_page = "Explain this page in plain words: what it says, and anything on it that needs context from earlier in the book.",
    just_happened = "What just happened? Briefly, the last few pages up to and including my page.",
    whos_who = "Who's who so far? The people (or key figures) who have come up by my page, most important first, "
        .. "one short line each: the name, then who they are.",
    recap = "Recap the book so far, up to my page, in a few short paragraphs.",
    explain_this = "Explain the passage I selected, in the context of the book so far.",
    meaning_here = "What does the passage I selected mean here, in this book's context?",
    go_on = "Your last answer ran out of room. Go on from exactly where it stopped, without repeating any of it.",
}

local FALLBACK_MODELS = {
    { id = "claude-opus-5-5", label = "Opus 5.5" },
    { id = "claude-sonnet-5-5", label = "Sonnet 5.5" },
    { id = "claude-haiku-5-5", label = "Haiku 5.5" },
}
local FALLBACK_EFFORTS = {
    { id = "low", label = "Low" }, { id = "medium", label = "Medium" }, { id = "high", label = "High" },
}

local function lib(name)
    local ok, m = pcall(require, name)
    if ok and type(m) == "table" then return m end
end

local function jev()
    local J = lib("quiet_jev")
    if J and J.available then
        local ok, yes = pcall(J.available)
        if ok and yes then return J end
    end
end

-- The AI this Kindle has (quiet_claude.lua: Claude, or an OpenAI-compatible service from keys.lua), or nil. With
-- none, Search & Ask is an offline search: no ask chips, suggestions or model line, and a question is searched for.
local function ai()
    local C = lib("quiet_claude")
    if C and C.available then
        local ok, yes = pcall(C.available)
        if ok and yes then return C end
    end
end

local function aiName()
    local C = ai()
    local ok, name = pcall(function() return C and C.name and C.name() end)
    return ok and name or "Claude"
end

-- Claude writes plain prose when asked, but just in case: no markdown symbols on the page.
local function plain(s)
    s = (s or ""):gsub("\r", "")
    s = s:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1"):gsub("`", "")
    s = s:gsub("\n#+%s*", "\n"):gsub("^#+%s*", "")
    s = s:gsub("\n%s*[%-%*]%s+", "\n• "):gsub("^%s*[%-%*]%s+", "• ")
    s = s:gsub("\n\n\n+", "\n\n")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Whether an answer says anything the reader would see (spaces and bare markup don't; review C4-CR2-2).
local function said(text)
    return plain(text):find("%S") ~= nil
end

-- A paragraph's sentences (the text after the last full stop included).
local function sentences(para)
    local out, pos = {}, 1
    while true do
        local _, e = para:find("[%.%!%?]%S*%s+", pos)
        if not e then break end
        out[#out + 1] = para:sub(pos, e):gsub("%s+$", "")
        pos = e + 1
    end
    if pos <= #para then out[#out + 1] = para:sub(pos) end
    return out
end

local function clip(s, n)
    s = (s or ""):gsub("%s+", " ")
    if #s <= n then return s end
    local cut = s:sub(1, n):gsub("[\192-\255][\128-\191]*$", "")
    return (cut:gsub("%s+%S*$", "")) .. "…"
end

local Ask = Sheet:extend{
    anchor = "bottom",
    is_always_active = true, -- taps reach the sheet while the keyboard is up
    focus_text = nil,
    focus_page = nil,
}

function Ask:init()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.ahead = G_reader_settings:isTrue("quiet_ask_ahead")
    self.jobs = {}
    self.thread = {}      -- Claude conversation while the sheet is open
    self.rpage = 1        -- page of the results
    self.kb_visible = false
    self.picker_open = false
    if self.focus_text then self.focus_text = Find.trim(self.focus_text) end
    if self.focus_text == "" then self.focus_text = nil end
    local px = Q.px
    local inner = self.W - 2 * px(56)
    self.input = InputText:new{
        text = "",
        hint = ai() and "Find in this book, or ask about it" or "Find in this book",
        face = Q.face(33),
        width = inner - px(30 + 44 + 20) - px(96) - px(10),
        bordersize = 0, padding = 0, margin = 0,
        focused = true,
        parent = self,
        enter_callback = function() self:submit(self.input:getText()) end,
        edit_callback = function() UIManager:nextTick(function() self:onInputEdited() end) end,
    }
    Sheet.init(self)
    self:knowBookWords()
end

-- The book's own words up to the page (its names above all), so that the keyboard's corrections leave them alone:
-- 2-quiet-keyboard.lua reads them from the field's parent, quiet_known_words. Collected in the background, once per
-- book and layout, then only the pages read since.
local book_words = { key = nil, page = 0, set = nil, job = nil }

function Ask:knowBookWords()
    local ui = self.ui
    local doc = ui and ui.document
    if not doc or not ui.rolling then return end
    local key = tostring(doc.file) .. "|" .. BookCtx.fingerprint(doc)
    if book_words.key ~= key then
        if book_words.job then book_words.job:cancel() end
        book_words.key, book_words.page, book_words.set, book_words.job = key, 0, {}, nil
    end
    self.quiet_known_words = book_words.set
    local page = BookCtx.currentPage(ui)
    if book_words.job or page <= book_words.page then return end
    local from, n = book_words.page + 1, doc:getPageCount()
    book_words.job = BookCtx.runAsync(function()
        local a = doc:getPageXPointer(from)
        local b
        if page < n then
            b = doc:getPageXPointer(page + 1)
        else
            -- this is a copy of the reader: moving to the end here moves nothing on screen
            pcall(function()
                doc:gotoPos(2 ^ 30)
                b = doc:getXPointer()
            end)
        end
        local text = a and b and a ~= b and doc:getTextFromXPointers(a, b, false) or ""
        local seen, out = {}, {}
        -- letters (accented: UTF-8 lead bytes \195-\201) with apostrophes inside, as the keyboard reads words; curly
        -- quotes, dashes (\226...) and no-break spaces (\194\160) end one ("“Queequeg”" is queequeg)
        for w in text:gmatch("[%a\195-\201][%a'\128-\191\195-\201]*") do
            w = w:lower():gsub("'+$", "")
            if #w >= 3 and not seen[w] then
                seen[w] = true
                out[#out + 1] = w
            end
        end
        return out
    end, function(words)
        if book_words.key ~= key then return end
        book_words.job = nil
        if type(words) ~= "table" then return end
        for _, w in ipairs(words) do book_words.set[w] = true end
        book_words.page = math.max(book_words.page, page)
    end)
end

function Ask:kbHeight()
    if not self.kb_visible then return 0 end
    local ok, d = pcall(function() return self.input:getKeyboardDimen() end)
    return ok and d and d.h or 0
end

-- Where the panel goes now (above the keyboard when it's up).
function Ask:regionNow()
    local b = Q.px(3)
    local bottom = self.H - self:kbHeight()
    local top = bottom - self.panel_h + b
    return Geom:new{ x = 0, y = top, w = self.W, h = bottom - top }
end

function Ask:paintTo(bb, x, y)
    local b = Q.px(3)
    local r = self:regionNow()
    self.panel:paintTo(bb, -b, r.y)
    self.panel_region = r
end

-- Rebuild in place and refresh what changed; when the panel moves or shrinks, the page under it is repainted too.
-- below_field: only what's under the field changed (typing), so the field, and the text going into it, are left out
-- of the e-ink update and never wait behind it.
function Ask:update(mode, below_field)
    if self.closed then return end
    local old = self.panel_region
    self:rebuild()
    local new = self:regionNow()
    local moved = not old or old.y ~= new.y or old.h ~= new.h
    local region = old and old:combine(new) or new
    if below_field and not moved and self.field_end then
        local top = new.y + self.field_end + 2 -- clear of the field row (see onInputEdited)
        region = Geom:new{ x = new.x, y = top, w = new.w, h = new.y + new.h - top }
    end
    UIManager:setDirty(moved and "all" or self, function() return mode or "ui", region end)
end

---------------------------------------------------------------------------------------------------- building

local function chip(label, cb, opts)
    opts = opts or {}
    local px = Q.px
    local h = px(opts.h or CHIP_H)
    local content = Q.text(label, opts.text_px or 28, { bold = opts.selected, max_width = opts.max_width })
    if opts.icon then
        content = HorizontalGroup:new{ align = "center", Q.icon(opts.icon, 36), Q.hspan(10), content }
    end
    local w = content:getSize().w + px(opts.pad or 56)
    local panel = Q.Panel:new{
        w = w, h = h, radii = { 999, 999, 999, 999 },
        border = opts.selected and Q.INK2 or Q.LINE, bw = px(3), fill = opts.selected and Q.SOFT or nil,
        content = CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, content },
    }
    return Q.Tap:new{ w = w, h = h, content = panel, callback = cb }
end

-- Chips flowed into as many rows as needed.
local function flow(widgets, width, gap)
    gap = gap or 16
    local g = Q.px(gap)
    local rows = VerticalGroup:new{ align = "left" }
    local row, used = HorizontalGroup:new{ align = "center" }, 0
    for _, w in ipairs(widgets) do
        local ww = w:getSize().w
        if used > 0 and used + g + ww > width then
            rows[#rows + 1] = row
            rows[#rows + 1] = Q.vspan(12)
            row, used = HorizontalGroup:new{ align = "center" }, 0
        end
        if used > 0 then
            row[#row + 1] = Q.hspan(gap)
            used = used + g
        end
        row[#row + 1] = w
        used = used + ww
    end
    if #row > 0 then rows[#rows + 1] = row end
    return rows
end

-- The one switch: an outlined pill (off) or a filled one (on), knob on the side it's set to.
local Switch = Widget:extend{ on = false }
function Switch:getSize() return Geom:new{ w = Q.px(92), h = Q.px(52) } end
function Switch:paintTo(bb, x, y)
    local w, h = Q.px(92), Q.px(52)
    local r = math.floor(h / 2)
    local b = Q.px(3)
    local k = h - 2 * Q.px(8)
    local kr = math.floor(k / 2)
    if self.on then
        Q.fillRound(bb, x, y, w, h, Q.INK2, r, r, r, r)
        Q.fillRound(bb, x + w - Q.px(8) - k, y + Q.px(8), k, k, Q.PAPER, kr, kr, kr, kr)
    else
        Q.fillRound(bb, x, y, w, h, Q.LINE, r, r, r, r)
        Q.fillRound(bb, x + b, y + b, w - 2 * b, h - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)
        Q.fillRound(bb, x + Q.px(8), y + Q.px(8), k, k, Q.LINE, kr, kr, kr, kr)
    end
end

local Rule = Widget:extend{ w = 0 }
function Rule:getSize() return Geom:new{ w = self.w, h = Q.px(2) } end
function Rule:paintTo(bb, x, y) bb:paintRect(x, y, self.w, Q.px(2), Q.TRACK) end

function Ask:textBox(text, px_size, width, opts)
    opts = opts or {}
    return TextBoxWidget:new{
        text = text,
        face = Q.face(px_size, opts.bold),
        width = width,
        fgcolor = opts.color or Q.INK,
        height = opts.height,
        height_overflow_show_ellipsis = opts.height ~= nil,
        line_height = opts.line_height or 0.3,
    }
end

function Ask:lineHeight(px_size)
    self._lh = self._lh or {}
    if not self._lh[px_size] then
        local t = TextBoxWidget:new{ text = "Ag", face = Q.face(px_size), width = Q.px(400), for_measurement_only = true }
        self._lh[px_size] = t:getLineHeight()
        t:free()
    end
    return self._lh[px_size]
end

function Ask:fieldRow(inner)
    local px = Q.px
    local text = self.input:getText()
    local clear = Q.Tap:new{
        w = px(96), h = px(FIELD_H),
        content = text ~= "" and Q.icon("close", 38) or Q.hspan(1),
        callback = function()
            if self.input:getText() ~= "" then self:clear() else self:showKeyboard() end
        end,
    }
    self.clear_tap = clear
    local row = HorizontalGroup:new{
        align = "center",
        Q.hspan(30), Q.icon("search", 44), Q.hspan(20),
        CenterContainer:new{ dimen = Geom:new{ w = self.input:getSize().w, h = px(FIELD_H) - px(12) }, self.input },
        Q.hspan(10), clear,
    }
    return Q.Panel:new{
        w = inner, h = px(FIELD_H), radii = { 999, 999, 999, 999 },
        border = self.kb_visible and Q.INK2 or Q.LINE, bw = px(3),
        content = LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(FIELD_H) }, row },
    }
end

function Ask:switchRow(inner)
    local px = Q.px
    local left = self.ahead and "About the whole book, what's ahead included" or "About this page and what you've read"
    local toggle = Q.Tap:new{
        w = px(330), h = px(SWITCH_ROW_H),
        content = HorizontalGroup:new{
            align = "center",
            Q.text("What's ahead", 29, { bold = self.ahead }), Q.hspan(16), Switch:new{ on = self.ahead },
        },
        callback = function() self:setAhead(not self.ahead) end,
    }
    return OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = px(SWITCH_ROW_H) },
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(SWITCH_ROW_H) },
            Q.text(left, 26, { color = Q.INK2, max_width = inner - px(350) }) },
        RightContainer:new{ dimen = Geom:new{ w = inner, h = px(SWITCH_ROW_H) }, toggle },
    }
end

function Ask:offerChips(offers, inner)
    local list = {}
    for _, o in ipairs(offers or {}) do
        list[#list + 1] = chip(o.label, function() self:goTo(o) end, { icon = o.kind == "chapter" and "contents" or "goto" })
    end
    if #list == 0 then return nil end
    return flow(list, inner)
end

function Ask:suggestionBlock(inner)
    local px = Q.px
    local vg = VerticalGroup:new{ align = "left" }
    if ai() then
        local list = {}
        for _, s in ipairs(self.focus_text and SUGGESTIONS.selection or SUGGESTIONS.page) do
            list[#list + 1] = chip(s.label, function() self:runSuggestion(s.id) end, { text_px = 27 })
        end
        vg[#vg + 1] = flow(list, inner, 14)
    end
    local recent = G_reader_settings:readSetting("quiet_ask_recent") or {}
    if #recent > 0 then
        local label = Q.text("Recent", 26, { color = Q.INK2 })
        local row = HorizontalGroup:new{ align = "center", label, Q.hspan(20) }
        local used = label:getSize().w + px(20)
        for i, r in ipairs(recent) do
            local t = Q.text(r, 28, { max_width = px(360) })
            local w = t:getSize().w + px(20)
            if used + w + px(40) > inner then break end
            if i > 1 then
                row[#row + 1] = Q.text("·", 28, { color = Q.INK2 })
                used = used + px(20)
            end
            row[#row + 1] = Q.Tap:new{ w = w, h = px(70), content = t, callback = function()
                self.input:setText(r)
                self:submit(r)
            end }
            used = used + w
        end
        vg[#vg + 1] = Q.vspan(10)
        vg[#vg + 1] = row
    end
    return vg
end

-- The quiet line at the bottom: Claude's model and effort; tap for the two rows of choices.
function Ask:footer(inner, keep_row)
    local px = Q.px
    local C = ai()
    local vg = VerticalGroup:new{ align = "left" }
    local nav
    if self.npages and self.npages > 1 then
        nav = HorizontalGroup:new{
            align = "center",
            Q.Tap:new{ w = px(84), h = px(64), content = Q.icon("prev", 40), callback = function() self:turn(-1) end },
            Q.text(self.rpage .. " of " .. self.npages, 26, { color = Q.INK2 }),
            Q.Tap:new{ w = px(84), h = px(64), content = Q.icon("next", 40), callback = function() self:turn(1) end },
        }
    end
    local line
    local models, efforts = self:models(), self:efforts()
    local choosable = #models > 1 or #efforts > 0 -- one model and no effort levels (another service): just its name
    if C then
        local words = self:labelOf(models, self:model())
        if #efforts > 0 then words = words .. " · " .. self:labelOf(efforts, self:effort()) end
        local hg = HorizontalGroup:new{ align = "center", Q.icon("spark", 30), Q.hspan(10),
            Q.text(words, 25, { color = Q.INK2, max_width = px(560) }) }
        if choosable then
            hg[#hg + 1] = Q.hspan(8)
            hg[#hg + 1] = Q.icon(self.picker_open and "up" or "down", 28)
        end
        line = Q.Tap:new{
            w = px(620), h = px(64),
            content = LeftContainer:new{ dimen = Geom:new{ w = px(620), h = px(64) }, hg },
            callback = function()
                if not choosable then return end
                self.picker_open = not self.picker_open
                self:update()
            end,
        }
    end
    if line or nav or keep_row then
        vg[#vg + 1] = OverlapGroup:new{
            dimen = Geom:new{ w = inner, h = px(64) },
            LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(64) }, line or Q.hspan(1) },
            RightContainer:new{ dimen = Geom:new{ w = inner, h = px(64) }, nav or Q.hspan(1) },
        }
    end
    if C and choosable and self.picker_open then
        local function choices(title, list, current, key)
            local chips = { }
            for _, it in ipairs(list) do
                chips[#chips + 1] = chip(it.label, function()
                    G_reader_settings:saveSetting(key, it.id)
                    self:update()
                end, { selected = it.id == current, h = 64, text_px = 26, pad = 44 })
            end
            local row = HorizontalGroup:new{ align = "center",
                LeftContainer:new{ dimen = Geom:new{ w = px(130), h = px(72) }, Q.text(title, 26, { color = Q.INK2 }) } }
            for i, c in ipairs(chips) do
                if i > 1 then row[#row + 1] = Q.hspan(12) end
                row[#row + 1] = c
            end
            return row
        end
        if #models > 1 then
            vg[#vg + 1] = Q.vspan(4)
            vg[#vg + 1] = choices("Model", models, self:model(), "quiet_ask_model")
        end
        if #efforts > 0 then
            vg[#vg + 1] = Q.vspan(8)
            vg[#vg + 1] = choices("Effort", efforts, self:effort(), "quiet_ask_effort")
        end
    end
    if #vg == 0 then return nil end
    return vg
end

-- Results as a list of items of known height, so they can be split into pages without building them all.
function Ask:resultItems(inner)
    local px = Q.px
    local items = {}
    local r = self.results
    local function add(h, make) items[#items + 1] = { h = h, make = make } end
    local function addWidget(w) local h = w:getSize().h; add(h, function() return w end) end
    local function gap(n) add(px(n), function() return Q.vspan(n) end) end

    -- plain words or a described moment: Claude is one tap away
    if (r.kind == "find" or r.kind == "goto" or r.kind == "moment") and not r.answer and ai() then
        addWidget(flow({ chip("Ask " .. aiName() .. " about “" .. clip(r.query, 28) .. "”", function()
            self:startAsk(r.query, r.query)
            self:update()
        end, { icon = "spark" }) }, inner))
        gap(20)
    end

    -- Claude's answer
    local a = r.answer
    if a then
        local status
        if a.status == "reading" then status = a.reading and ("Reading " .. a.reading .. " pages…") or "Reading…"
        elseif a.status == "wifi" then status = "Turning on Wi-Fi…"
        elseif a.status == "waiting" then status = "Thinking…"
        elseif a.status == "streaming" then status = "Writing…" end
        addWidget(OverlapGroup:new{
            dimen = Geom:new{ w = inner, h = px(60) },
            LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(60) }, HorizontalGroup:new{ align = "center",
                Q.icon("spark", 40), Q.hspan(14), Q.text(a.by or aiName(), 29, { bold = true }) } },
            RightContainer:new{ dimen = Geom:new{ w = inner, h = px(60) },
                Q.text(status or "", 26, { color = Q.INK2 }) },
        })
        if a.question and a.question ~= "" then
            addWidget(self:textBox(a.question, 29, inner, { bold = true, color = Q.INK2 }))
            gap(10)
        end
        local has_text = said(a.text)
        if a.status == "error" and not has_text then
            addWidget(self:textBox(a.error or "Something went wrong.", 30, inner))
            gap(14)
            if ai() then addWidget(flow({ chip("Try again", function() self:retryAsk() end) }, inner)) end
        elseif has_text then
            -- paragraph by paragraph, so a long answer pages cleanly; a paragraph taller than a page is split into
            -- pieces that each fit one (fitPieces), never cut short
            local maxh = (self.results_h or self.H) - px(20)
            for para in (plain(a.text) .. "\n\n"):gmatch("(.-)\n\n") do
                if para:find("%S") then
                    local tb = self:textBox(para, 31, inner)
                    if tb:getSize().h <= maxh then
                        add(tb:getSize().h, function() return tb end)
                    else
                        tb:free()
                        for _, piece in ipairs(self:fitPieces(para, 31, inner, maxh)) do
                            local ptb = self:textBox(piece, 31, inner)
                            add(ptb:getSize().h, function() return ptb end)
                        end
                    end
                    gap(14)
                end
            end
            if a.status == "error" then
                -- what arrived before it stopped stays readable (review C4-CF-3)
                addWidget(self:textBox("Stopped here: " .. (a.error or "something went wrong."), 26, inner, { color = Q.INK2 }))
                gap(14)
                if ai() then addWidget(flow({ chip("Try again", function() self:retryAsk() end) }, inner)) end
            elseif a.status == "done" then
                if a.cut then
                    -- ran out of room (max_tokens, or the context window): say so instead of passing it off as
                    -- complete (review C4-CF-4). Go on carries on in the same conversation, so only while it's
                    -- still the one going
                    addWidget(self:textBox("Cut off here: the answer ran out of room.", 26, inner, { color = Q.INK2 }))
                    if ai() and self.thread_ctx and self.thread_ahead == self.ahead and self.thread_ai == self:aiKey() then
                        gap(14)
                        addWidget(flow({ chip("Go on", function() self:askAs("Go on", PROMPTS.go_on) end) }, inner))
                    end
                    gap(14)
                end
                local cites = Find.citations(a.text, self.ui.document:getPageCount())
                if #cites > 0 then
                    local chips = {}
                    for _, c in ipairs(cites) do
                        chips[#chips + 1] = chip(Find.citationLabel(c), function() self:goTo({ kind = "page", page = c.from }) end,
                            { h = 64, text_px = 26, pad = 44 })
                    end
                    addWidget(flow(chips, inner, 12))
                    gap(10)
                end
                if a.span then
                    addWidget(self:textBox(a.span, 25, inner, { color = Q.INK2 }))
                end
            end
        elseif a.status == "done" then
            -- finished without a word: say so rather than show nothing
            addWidget(self:textBox((a.by or aiName()) .. " didn't say anything this time.", 30, inner))
            gap(14)
            if ai() then addWidget(flow({ chip("Try again", function() self:retryAsk() end) }, inner)) end
        end
        gap(24)
    end

    -- the passage closest to what was typed
    local p = r.passage
    if p and p.status ~= "none" then
        local title = (p.by == "jev" and "Close in meaning") or "Closest passage"
        if p.status == "done" then
            addWidget(Q.text(title, 26, { bold = true, color = Q.INK2 }))
            gap(6)
            local lh = self:lineHeight(30)
            local body = self:textBox("“" .. clip(p.text, 600) .. "”", 30, inner - px(110), { height = lh * 5 })
            local row = OverlapGroup:new{
                dimen = Geom:new{ w = inner, h = body:getSize().h },
                LeftContainer:new{ dimen = Geom:new{ w = inner, h = body:getSize().h }, body },
                RightContainer:new{ dimen = Geom:new{ w = inner, h = body:getSize().h },
                    Q.text("p " .. p.page, 27, { color = Q.INK2 }) },
            }
            local h = body:getSize().h
            add(h, function()
                return Q.Tap:new{ w = inner, h = h, content = row, capsule_radius = 24,
                    callback = function() self:goTo({ kind = "page", page = p.page }) end }
            end)
            gap(24)
        elseif p.status == "error" then
            addWidget(Q.text(title .. ": couldn't read the book", 26, { color = Q.INK2 }))
            gap(24)
        else
            local what = p.reading and ("Reading " .. p.reading .. " pages…") or "Looking for the passage…"
            addWidget(Q.text(title .. " · " .. what, 26, { color = Q.INK2 }))
            gap(24)
        end
    end

    -- same words
    local f = r.find
    if f then
        local hits, hidden = {}, 0
        local here = BookCtx.currentPage(self.ui)
        for _, h in ipairs(f.hits or {}) do
            if self.ahead or (h.page or 0) <= here then hits[#hits + 1] = h else hidden = hidden + 1 end
        end
        local count = f.hits and (#hits .. ((f.hits.capped and self.ahead) and "+" or "")) or ""
        local head = "“" .. clip(f.term, 40) .. "”" .. (f.hits and (" · " .. count) or "")
        addWidget(Q.text(head, 26, { bold = true, color = Q.INK2 }))
        gap(6)
        if f.searching then
            addWidget(Q.text("Looking…", 28, { color = Q.INK2 }))
        elseif f.error then
            addWidget(Q.text("The search didn't work this time.", 28, { color = Q.INK2 }))
        elseif #hits == 0 then
            local msg
            if hidden > 0 then
                msg = "Nothing before your page. " .. hidden .. (hidden == 1 and " match" or " matches")
                    .. " further on, hidden while What's ahead is off."
            else
                msg = "No matches in this book."
            end
            addWidget(self:textBox(msg, 28, inner, { color = Q.INK2 }))
        else
            local lh = self:lineHeight(29)
            local row_h = 2 * lh + px(24)
            local hide_ahead = not self.ahead
            for _, h in ipairs(hits) do
                add(row_h, function() return self:hitRow(h, inner, row_h, 2 * lh, hide_ahead) end)
            end
            if hidden > 0 then
                gap(10)
                addWidget(self:textBox(hidden .. " more further on, hidden while What's ahead is off", 25, inner,
                    { color = Q.INK2 }))
            end
        end
        gap(20)
    end

    if r.routing then
        addWidget(Q.text("Looking…", 28, { color = Q.INK2 }))
    end
    return items
end

-- Ways to cut a paragraph, coarsest first: at its line breaks (a list), at sentence ends, between words.
local SPLITS = {
    function(t)
        local units = {}
        for line in (t .. "\n"):gmatch("([^\n]*)\n") do
            if line:find("%S") then units[#units + 1] = line end
        end
        return units, "\n"
    end,
    function(t)
        local units = sentences(t)
        if #units > 1 then return units, " " end
        -- Chinese and Japanese end sentences with their own marks and no space
        units = {}
        -- (each mark is three bytes: plain replacements, not a character class, which would match single bytes)
        local marked = t:gsub("。", "。\0"):gsub("！", "！\0"):gsub("？", "？\0")
        for s in marked:gmatch("([^%z]+)") do units[#units + 1] = s end
        return units, ""
    end,
    function(t)
        local units = {}
        for w in t:gmatch("%S+") do units[#units + 1] = w end
        return units, " "
    end,
    -- text with no spaces at all: between characters (one always fits a page)
    function(t)
        local units = {}
        for ch in t:gmatch("[%z\1-\127\194-\244][\128-\191]*") do units[#units + 1] = ch end
        return units, ""
    end,
}

function Ask:fitsPage(text, px_size, width, maxh)
    local tb = self:textBox(text, px_size, width)
    local h = tb:getSize().h
    tb:free()
    return h <= maxh
end

-- A paragraph as pieces that each fit a results page (maxh), in order, nothing left out: as many whole lines as
-- fit, else sentences, else words (a binary search for the longest run that fits, so a long paragraph costs a few
-- dozen measurements, not one per word). A single word taller than a page (never in real text) stays whole.
function Ask:fitPieces(text, px_size, width, maxh, level)
    level = level or 1
    local split = SPLITS[level]
    if not split or self:fitsPage(text, px_size, width, maxh) then return { text } end
    local units, sep = split(text)
    if #units < 2 then return self:fitPieces(text, px_size, width, maxh, level + 1) end
    local out, i = {}, 1
    while i <= #units do
        if not self:fitsPage(units[i], px_size, width, maxh) then
            for _, piece in ipairs(self:fitPieces(units[i], px_size, width, maxh, level + 1)) do out[#out + 1] = piece end
            i = i + 1
        else
            local lo, hi = i, #units
            while lo < hi do
                local mid = math.floor((lo + hi + 1) / 2)
                if self:fitsPage(table.concat(units, sep, i, mid), px_size, width, maxh) then lo = mid else hi = mid - 1 end
            end
            out[#out + 1] = table.concat(units, sep, i, lo)
            i = lo + 1
        end
    end
    return out
end

-- hide_ahead: What's ahead is off, so the words after the match stop where the reader's page does (next_here).
function Ask:hitRow(h, inner, row_h, text_h, hide_ahead)
    local px = Q.px
    local PTF = TextBoxWidget.PTF_HEADER
    local B0, B1 = TextBoxWidget.PTF_BOLD_START, TextBoxWidget.PTF_BOLD_END
    local prev = (h.prev or ""):gsub("%s+", " ")
    local nxt = ((hide_ahead and h.next_here) or h.next or ""):gsub("%s+", " ")
    if prev ~= "" and not prev:find("%s$") then prev = prev .. " " end
    if nxt ~= "" and not nxt:find("^[%s%p]") then nxt = " " .. nxt end
    local text = PTF .. "…" .. prev .. B0 .. (h.match or "") .. B1 .. nxt .. "…"
    local body = TextBoxWidget:new{
        text = text, face = Q.face(29), width = inner - px(110), height = text_h,
        height_overflow_show_ellipsis = true, line_height = 0.3,
    }
    local og = OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = row_h },
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = row_h }, body },
        RightContainer:new{ dimen = Geom:new{ w = inner, h = row_h },
            Q.text("p " .. (h.page or "?"), 27, { color = Q.INK2 }) },
    }
    return Q.Tap:new{ w = inner, h = row_h, content = og, capsule_radius = 24,
        callback = function() self:goTo({ kind = "hit", hit = h }) end }
end

-- Greedy pages of results; returns the widgets of the current page and its height.
function Ask:resultsPage(items, max_h)
    local pages, cur, used = {}, {}, 0
    for _, it in ipairs(items) do
        if used + it.h > max_h and #cur > 0 then
            pages[#pages + 1] = cur
            cur, used = {}, 0
        end
        cur[#cur + 1] = it
        used = used + it.h
    end
    if #cur > 0 then pages[#pages + 1] = cur end
    self.npages = #pages
    if self.rpage > #pages then self.rpage = math.max(1, #pages) end
    local vg = VerticalGroup:new{ align = "left" }
    for _, it in ipairs(pages[self.rpage] or {}) do vg[#vg + 1] = it.make() end
    return vg
end

function Ask:build()
    local W, H, px = self.W, self.H, Q.px
    local inner = W - 2 * px(56)
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0 -- groups cache their size once measured: count heights as they go in instead
    local function add(w)
        vg[#vg + 1] = w
        used = used + w:getSize().h
    end
    add(Q.vspan(20))
    add(CenterContainer:new{ dimen = Geom:new{ w = inner, h = px(10) }, Sheet.grip() })
    add(Q.vspan(16))
    add(self:fieldRow(inner))
    self.field_end = used + px(3) -- the group sits 3 px down in the panel (panel_h below)
    add(Q.vspan(6))
    add(self:switchRow(inner))
    if self.focus_text then
        add(self:textBox("“" .. clip(self.focus_text, 300) .. "”", 27, inner,
            { color = Q.INK2, height = 2 * self:lineHeight(27) }))
        add(Q.vspan(6))
    end
    local text = self.input:getText()
    self.npages = nil
    if self.kb_visible then
        local offers = self:offerChips(Find.offers(text, self:offerCtx()), inner)
        if offers then add(Q.vspan(8)); add(offers) end
        if text == "" and not self.results then add(Q.vspan(12)); add(self:suggestionBlock(inner)) end
        add(Q.vspan(24))
        -- while typing, the sheet keeps the height it came up with: the field stays put and the page under the
        -- sheet isn't redrawn each time a suggestion comes or goes
        if self.kb_min_h and used < self.kb_min_h then add(VerticalSpan:new{ width = self.kb_min_h - used }) end
        self.kb_min_h = math.max(self.kb_min_h or 0, used)
    elseif self.results then
        local offers = self:offerChips(self.results.offers, inner)
        if offers then add(Q.vspan(8)); add(offers) end
        add(Q.vspan(18))
        add(Rule:new{ w = inner })
        add(Q.vspan(18))
        -- the results get whatever height is left on the screen; the footer is measured first
        local footer = self:footer(inner, true)
        local fixed = used + footer:getSize().h + px(16 + 20 + 12)
        local max_h = H - px(TOP_GAP) - fixed
        self.results_h = max_h
        local items = self:resultItems(inner)
        local page = self:resultsPage(items, max_h)
        add(page)
        add(Q.vspan(16))
        add(self:footer(inner, true)) -- again: it shows the page count, known only now
        add(Q.vspan(20))
    else
        add(Q.vspan(12))
        add(self:suggestionBlock(inner))
        add(Q.vspan(18))
        local footer = self:footer(inner)
        if footer then add(footer) end
        add(Q.vspan(20))
    end
    self.panel_h = used + px(6)
    self.content = CenterContainer:new{ dimen = Geom:new{ w = W, h = self.panel_h }, vg }
end

---------------------------------------------------------------------------------------------------- choices

-- Which AI a conversation belongs to: a different service or book budget (keys.lua changed) starts a new one,
-- whose book text is measured for it (review C8-4).
function Ask:aiKey()
    local C = ai()
    if not C then return "none" end
    local ok, key = pcall(function()
        if C.identity then return C.identity() end
        return tostring(C.provider()) .. "|" .. tostring((C.bookChars()))
    end)
    return ok and key or "?"
end

function Ask:models()
    local C = lib("quiet_claude")
    if C and C.models then return C.models() end
    return C and C.MODELS or FALLBACK_MODELS
end

function Ask:efforts()
    local C = lib("quiet_claude")
    if C and C.efforts then return C.efforts() end
    return C and C.EFFORTS or FALLBACK_EFFORTS
end

local function has(list, id)
    for _, it in ipairs(list) do if it.id == id then return true end end
    return false
end

function Ask:labelOf(list, id)
    for _, it in ipairs(list) do if it.id == id then return it.label end end
    return id or ""
end

function Ask:model()
    local list = self:models()
    local id = G_reader_settings:readSetting("quiet_ask_model")
    if id and has(list, id) then return id end
    local C = lib("quiet_claude")
    if C and C.DEFAULT_MODEL and has(list, C.DEFAULT_MODEL) then return C.DEFAULT_MODEL end
    return list[1] and list[1].id
end

function Ask:effort()
    local list = self:efforts()
    local id = G_reader_settings:readSetting("quiet_ask_effort")
    if id and has(list, id) then return id end
    local C = lib("quiet_claude")
    if C and C.DEFAULT_EFFORT and has(list, C.DEFAULT_EFFORT) then return C.DEFAULT_EFFORT end
    if has(list, "high") then return "high" end
    return list[#list] and list[#list].id
end

-- Read once per sheet: the chapters and page count don't change while it's open, and this ran on every key.
function Ask:offerCtx()
    if not self._offer_ctx then
        local toc = {}
        if self.ui.toc then
            pcall(function() self.ui.toc:fillToc() end)
            toc = self.ui.toc.toc or {}
        end
        self._offer_ctx = { total = self.ui.document:getPageCount(), toc = toc }
    end
    return self._offer_ctx
end

---------------------------------------------------------------------------------------------------- input

function Ask:onInputEdited()
    if self.closed or not self.input then return end
    local text = self.input:getText()
    local offers = Find.offers(text, self:offerCtx())
    local sig = (text == "" and "empty" or "text")
    for _, o in ipairs(offers) do sig = sig .. "|" .. o.label end
    if sig ~= self._edit_sig then
        -- the first letter or a cleared field also shows or hides the field's × (in the field row): the whole sheet
        -- then; after that only what's under the field changes
        local flipped = not self._edit_sig or (self._edit_sig:sub(1, 5) == "empty") ~= (text == "")
        self._edit_sig = sig
        if self.kb_visible then
            -- only what's under the field (the text itself is the keyboard's: DU, no flash), and the field's x when
            -- it comes or goes; REAGL here would hold KOReader ~0.2 s between two letters
            self:update(nil, true)
            if flipped then
                local x = self.clear_tap
                -- inset: KOReader merges redraws that touch, and this one and the one under the field would then
                -- take the letter's own DU redraw (between them) into one "ui"
                UIManager:setDirty(nil, function()
                    local d = x and x.dimen
                    if d and d.x then return "ui", Geom:new{ x = d.x + 4, y = d.y + 4, w = d.w - 8, h = d.h - 8 } end
                end)
            end
        end
    end
end

-- InputText calls this when its field is tapped: bring the keyboard up and move the sheet above it.
function Ask:onSwitchFocus()
    self:showKeyboard()
end

function Ask:showKeyboard()
    if self.closed then return end
    if not self.kb_visible then self.kb_min_h = nil end -- a tap in the field while typing keeps the height
    self.input:onShowKeyboard()
    self.kb_visible = self.input:isKeyboardVisible()
    self:update()
end

function Ask:hideKeyboard(no_refresh)
    if not self.kb_visible then return end
    self.input:onCloseKeyboard()
    self.kb_visible = false
    if not no_refresh then self:update() end
end

function Ask:clear()
    self.input:setText("")
    self:showKeyboard()
end

function Ask:remember(q)
    local list = G_reader_settings:readSetting("quiet_ask_recent") or {}
    local out = { q }
    for _, r in ipairs(list) do
        if r ~= q and #out < RECENT_MAX then out[#out + 1] = r end
    end
    G_reader_settings:saveSetting("quiet_ask_recent", out)
end

-- The switch decides what anything still running may read, so work started under the other setting starts
-- over: an answer still on its way is asked again (a new conversation), a passage is looked for again.
-- A finished answer stays as it is: its last line says whether it read what's ahead.
function Ask:setAhead(on)
    if on == self.ahead then return end
    self.ahead = on
    G_reader_settings:saveSetting("quiet_ask_ahead", on)
    local r = self.results
    if r then
        local a = r.answer
        if a and a.status ~= "done" and a.status ~= "error" then self:startAsk(a.question, a.prompt) end
        local p = r.passage
        if p and p.query then self:startPassage(p.query, p.for_ask) end
    end
    self:update()
end

function Ask:turn(dir)
    if not self.npages or self.npages < 2 then return end
    local p = math.max(1, math.min(self.npages, self.rpage + dir))
    if p ~= self.rpage then
        self.rpage = p
        self:update()
    end
end

---------------------------------------------------------------------------------------------------- running

function Ask:cancelJob(name)
    local j = self.jobs[name]
    self.jobs[name] = nil
    if j and j.cancel then pcall(function() j:cancel() end) end
end

-- Stop a question still being answered; a question that got no answer leaves the conversation (turns must
-- alternate between the reader and Claude).
function Ask:dropAsk()
    self.ask_op = nil
    self:cancelJob("ask"); self:cancelJob("ctx"); self:cancelJob("wifi")
    local last = self.thread[#self.thread]
    if last and last.role == "user" then table.remove(self.thread) end
end

-- Is `a` still the question being answered? Results being replaced, a new question, the switch, closing: no.
-- (An answer left unchanged in a results table that was replaced doesn't count: that table is no longer shown.)
function Ask:isCurrentAsk(r, a)
    return not self.closed and self.results == r and r.answer == a and self.ask_op == a
end

function Ask:cancelAll()
    for name in pairs(self.jobs) do self:cancelJob(name) end
    if self._refresh_task then
        UIManager:unschedule(self._refresh_task)
        self._refresh_task = nil
    end
end

function Ask:submit(text)
    local q = Find.trim(text)
    if q == "" or self.closed then return end
    self:remember(q)
    self:hideKeyboard(true)
    local kind = Find.route(q)
    local look_for = q
    if kind == "ask" and not ai() then
        -- no AI: a question is searched for the words it asks about ("Who is Mr. Darcy?" -> Darcy)
        kind, look_for = "find", Find.term(q, "ask") or q
    end
    -- a follow-up keeps the conversation; plain words stay a search. Everything the old results still had
    -- running stops (not just goes unheard: a Jev routing call would otherwise retry on its own).
    self:dropAsk()
    self:cancelAll()
    self.results = { query = look_for, kind = kind, offers = Find.offers(q, self:offerCtx()), answer = nil }
    self.rpage = 1
    if kind == "goto" or kind == "find" then
        self:startFind(look_for)
    elseif kind == "ask" then
        local term = Find.term(q, "ask")
        if term then self:startFind(term) end
        self:startAsk(q, q)
    else
        local J = ai() and jev() -- Jev only decides between finding and asking, so it waits for an AI
        if J then
            self:routeWithJev(J, q)
        else
            self:startMoment(q)
        end
    end
    self:update()
end

function Ask:runSuggestion(id)
    local label
    for _, list in pairs(SUGGESTIONS) do
        for _, s in ipairs(list) do if s.id == id then label = s.label end end
    end
    if not label then return end
    self:askAs(label, PROMPTS[id] or label)
end

-- A question from a chip: `label` in the field, `prompt` to Claude.
function Ask:askAs(label, prompt)
    if self.closed then return end
    self:hideKeyboard(true)
    self.input:setText(label)
    self:dropAsk()
    self:cancelAll()
    self.results = { query = label, kind = "ask", offers = {} }
    self.rpage = 1
    self:startAsk(label, prompt)
    self:update()
end

function Ask:routeWithJev(J, q)
    local r = self.results
    self:cancelJob("jev")
    r.routing = true
    local ok, job = pcall(J.choice, {
        state = q,
        question = "This is what a reader typed into the search box of the book they're reading. What do they want?",
        options = {
            "To find the place in the book that this describes",
            "An answer to a question about the book",
            "To find these exact words in the book",
        },
        callback = function(res)
            if self.closed or self.results ~= r or not r.routing then return end
            r.routing = nil
            local idx = res and res.index or 1
            if idx == 2 then
                r.kind = "ask"
                local term = Find.term(q, "ask")
                if term then self:startFind(term) end
                self:startAsk(q, q)
            elseif idx == 3 then
                r.kind = "find"
                self:startFind(q)
            else
                self:startMoment(q)
            end
            self:update()
        end,
    })
    if ok then
        self.jobs.jev = job
    else
        r.routing = nil
        self:startMoment(q)
    end
end

function Ask:startFind(term)
    local r = self.results
    self:cancelJob("find")
    r.find = { term = term, searching = true }
    self.jobs.find = Find.run(self.ui, term, function(hits, err)
        self.jobs.find = nil
        if self.closed or self.results ~= r or not r.find or r.find.term ~= term then return end
        r.find.searching = false
        if hits then r.find.hits = hits else r.find.error = err end
        if err then logger.warn("quiet ask: search failed:", err) end
        self:update()
    end)
end

function Ask:startMoment(q)
    local r = self.results
    r.kind = "moment"
    local term = Find.term(q, "moment")
    if term then self:startFind(term) end
    self:startPassage(q, false)
end

-- The passage closest to q: shared words narrow the book down to 40 candidates, Jev picks one (when it's there).
-- for_ask: alongside a Claude answer, shown only when Jev picked it.
function Ask:startPassage(q, for_ask)
    local r = self.results
    self:cancelJob("pages"); self:cancelJob("rank"); self:cancelJob("jev_pick")
    -- this search, by identity: answers for an earlier one (another query, the other switch setting) are ignored
    local pass = { status = "reading", query = q, for_ask = for_ask }
    r.passage = pass
    local function live() return not self.closed and self.results == r and r.passage == pass end
    local function found(text, page, by)
        pass.status, pass.text, pass.page, pass.by = "done", text, page, by
    end
    local doc = self.ui.document
    local last = self.ahead and doc:getPageCount() or BookCtx.currentPage(self.ui)
    self.jobs.pages = BookCtx.ensure(self.ui, last, function(count)
        pass.reading = count
    end, function(pages, err)
        if not live() then return end
        self.jobs.pages = nil
        if not pages then
            if for_ask then r.passage = nil else pass.status = "error" end
            logger.warn("quiet ask: couldn't read the book:", err)
            self:update()
            return
        end
        pass.status = "ranking"
        pass.reading = nil
        self.jobs.rank = BookCtx.runAsync(function()
            return Find.rank(Find.paragraphs(pages, 1, last), q, 40)
        end, function(ranked)
            if not live() then return end
            self.jobs.rank = nil
            if not ranked or #ranked == 0 then
                if for_ask then r.passage = nil else pass.status = "none" end
                self:update()
                return
            end
            local J = jev()
            if not J then
                if for_ask then r.passage = nil else found(ranked[1].text, ranked[1].page, "words") end
                self:update()
                return
            end
            local options = {}
            for i, p in ipairs(ranked) do options[i] = clip(p.text, 360) end
            local question = for_ask and "Which passage best answers the reader's question about the book?"
                or "The reader describes a passage of their book. Which passage are they looking for?"
            local ok, job = pcall(J.choice, {
                state = q,
                question = question,
                options = options,
                callback = function(res)
                    if not live() then return end
                    self.jobs.jev_pick = nil
                    local pick = res and res.index and ranked[res.index]
                    if pick then
                        found(pick.text, pick.page, "jev")
                    elseif not for_ask then
                        found(ranked[1].text, ranked[1].page, "words")
                    else
                        r.passage = nil
                    end
                    self:update()
                end,
            })
            if ok then
                self.jobs.jev_pick = job
            else
                if for_ask then r.passage = nil else found(ranked[1].text, ranked[1].page, "words") end
                self:update()
            end
        end)
    end)
end

-- Ask Claude. question: what the sheet shows; prompt: what's sent (a suggestion's fuller wording).
function Ask:startAsk(question, prompt)
    local r = self.results
    local C = lib("quiet_claude")
    self:dropAsk()
    -- the AI asked and its book budget are fixed now: the book text is measured for them, and start() sends nothing
    -- if the AI is another one by then, however keys.lua changed in between (review C8-4/5, rounds 2 and 3)
    local a = { question = question, prompt = prompt, status = "reading", text = "", by = aiName(), ai = self:aiKey() }
    local okb, budget = pcall(function() return C and C.bookChars and C.bookChars() end)
    a.budget = okb and budget or nil
    r.answer = a
    self.ask_op = a
    self.last_ask = { question = question, prompt = prompt }
    -- the reader asked: a routing answer still on its way no longer decides anything
    if r.routing then
        self:cancelJob("jev")
        r.routing = nil
    end
    local ok_av, available = pcall(function() return C and C.available() end)
    if not (ok_av and available) then
        a.status, a.error = "error", "No AI is set up on this Kindle (settings/quiet/keys.lua)."
        return
    end
    -- a new conversation when there's none yet or the switch changed since
    local fresh = not self.thread_ctx or self.thread_ahead ~= self.ahead or self.thread_ai ~= self:aiKey()
    local function send(ctx)
        if not self:isCurrentAsk(r, a) then return end
        if jev() and prompt == question then self:startPassage(question, true) end
        local turn
        if #self.thread == 0 then
            turn = self:firstTurn(ctx, prompt)
        else
            turn = prompt
        end
        self.thread[#self.thread + 1] = { role = "user", text = turn }
        local turns = {}
        for i, t in ipairs(self.thread) do turns[i] = t end
        local span = (a.by or aiName()) .. " read pages " .. ctx.first_page .. "–" .. ctx.last_page
            .. (ctx.ahead and " · including what's ahead" or " · nothing past your page")
        a.span = span
        local function start()
            if not self:isCurrentAsk(r, a) then return end
            -- keys.lua changed while this question waited (for Wi-Fi or the book's text): its text was measured for
            -- the AI it was asked of, so it isn't sent to another one (review C8-4/5, round 2)
            if self:aiKey() ~= a.ai then
                a.status, a.error = "error", "The AI on this Kindle changed while this was waiting. Ask again."
                self.thread_ctx = nil
                if self.thread[#self.thread] and self.thread[#self.thread].role == "user" then table.remove(self.thread) end
                self:update()
                return
            end
            a.status = "waiting"
            self:update()
            local ok, job = pcall(C.stream, {
                model = self:model(),
                effort = self:effort(),
                system = BookCtx.system(self.ui.doc_props, self.thread_ahead),
                book = BookCtx.blocks(ctx),
                turns = turns,
                on_text = function(delta, so_far)
                    if not self:isCurrentAsk(r, a) then return end
                    a.status = "streaming"
                    a.text = so_far or ((a.text or "") .. (delta or ""))
                    self:refreshSoon()
                end,
                on_done = function(text, info)
                    if not self:isCurrentAsk(r, a) then return end
                    self.jobs.ask = nil
                    a.status = "done"
                    a.text = text or a.text
                    local why = type(info) == "table" and info.stop_reason
                    a.cut = why == "max_tokens" or why == "model_context_window_exceeded"
                    if said(a.text) then
                        self.thread[#self.thread + 1] = { role = "assistant", text = a.text }
                        self.input.hint = "Ask a follow-up"
                        if self.input:getText() == question then self.input:setText("") end
                    elseif self.thread[#self.thread] and self.thread[#self.thread].role == "user" then
                        -- nothing said: like a question that failed, it stays out of the conversation
                        table.remove(self.thread)
                    end
                    self:update("partial")
                end,
                on_error = function(message, info)
                    if not self:isCurrentAsk(r, a) then return end
                    self.jobs.ask = nil
                    -- this question didn't get an answer: leave it out of the conversation
                    if self.thread[#self.thread] and self.thread[#self.thread].role == "user" then
                        table.remove(self.thread)
                    end
                    -- what arrived stays readable (shown with the error), except an answer the safety check stopped
                    if type(info) == "table" and info.kind == "refusal" then a.text = "" end
                    a.status, a.error = "error", message or (aiName() .. " didn't answer.")
                    self:update()
                end,
            })
            if ok then
                self.jobs.ask = job
            else
                table.remove(self.thread)
                a.status, a.error = "error", "Couldn't reach " .. aiName() .. "."
                logger.warn("quiet ask: stream failed to start:", job)
                self:update()
            end
        end
        self:whenOnline(r, a, start)
    end
    if fresh then
        self.thread = {}
        self.thread_ctx, self.thread_ahead, self.thread_ai = nil, self.ahead, self:aiKey()
        self.jobs.ctx = BookCtx.build(self.ui, { ahead = self.ahead, focus_text = self.focus_text, focus_page = self.focus_page,
            budget = a.budget },
            function(count)
                a.reading = count
            end,
            function(ctx, err)
                if not self:isCurrentAsk(r, a) then return end
                self.jobs.ctx = nil
                if not ctx then
                    a.status, a.error = "error", "Couldn't read the book this time."
                    logger.warn("quiet ask: book context failed:", err)
                    self:update()
                    return
                end
                -- no text to read (a scanned PDF, a comic): say so instead of asking Claude about nothing
                if ctx.letters == 0 and ctx.focus_kind ~= "selection" then
                    a.status, a.error = "error", "There's no text on these pages that " .. aiName() .. " can read (a scanned book?)."
                    self:update()
                    return
                end
                self.thread_ctx = ctx
                send(ctx)
            end)
    else
        send(self.thread_ctx)
    end
end

function Ask:retryAsk()
    local last = self.last_ask
    if not last or not self.results then return end
    self:startAsk(last.question, last.prompt)
    self:update()
end

-- Where the reader is, what they're looking at, then the question: everything that changes per page.
function Ask:firstTurn(ctx, prompt)
    local lines = {}
    lines[#lines + 1] = "I'm on page " .. ctx.page .. " of " .. (ctx.total or "?")
        .. ((ctx.chapter and ctx.chapter ~= "") and (", in “" .. ctx.chapter .. "”") or "") .. "."
    if ctx.focus_kind == "selection" then
        lines[#lines + 1] = "The passage I selected (p " .. ctx.focus_page .. "):"
        lines[#lines + 1] = "“" .. ctx.focus .. "”"
    else
        lines[#lines + 1] = "The page I'm on (p " .. ctx.focus_page .. "):"
        lines[#lines + 1] = ctx.focus
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = prompt
    return table.concat(lines, "\n")
end

-- Run fn once online; says "Turning on Wi-Fi…" meanwhile, and says so when Wi-Fi doesn't come. The wait is a job
-- of the question (jobs.wifi): a new question, the switch or closing the sheet ends it, and fn never runs then.
function Ask:whenOnline(r, a, fn)
    local Net = lib("quiet_net")
    if not (Net and Net.whenOnline) then
        a.status, a.error = "error", "Couldn't get online. Check Wi-Fi and try again."
        self:update()
        return
    end
    if Net.isOnline and Net.isOnline() then
        fn()
        return
    end
    a.status = "wifi"
    self:update()
    local fired, handle = false, nil
    local fail
    local function stop()
        fired = true
        UIManager:unschedule(fail)
        if handle and handle.cancel then pcall(handle.cancel, handle) end
    end
    local job = { cancel = stop }
    local function release()
        if self.jobs.wifi == job then self.jobs.wifi = nil end
    end
    local function go()
        if fired then return end
        stop()
        release()
        fn()
    end
    fail = function()
        if fired then return end
        stop()
        release()
        if not self:isCurrentAsk(r, a) then return end
        a.status, a.error = "error", "Couldn't get online. Check Wi-Fi and try again."
        self:update()
    end
    self.jobs.wifi = job
    handle = Net.whenOnline(go, fail)
    if not fired then UIManager:scheduleIn(60, fail) end
end

-- While an answer streams: one refresh per REFRESH_EVERY seconds at most.
function Ask:refreshSoon()
    if self._refresh_task then return end
    self._refresh_task = function()
        self._refresh_task = nil
        self:update()
    end
    UIManager:scheduleIn(REFRESH_EVERY, self._refresh_task)
end

function Ask:goTo(o)
    local ui = self.ui
    if ui.link then pcall(function() ui.link:addCurrentLocationToStack() end) end
    self:close()
    UIManager:nextTick(function()
        if o.kind == "hit" then
            local h = o.hit
            if ui.rolling and type(h.start) == "string" then
                ui.rolling:onGotoXPointer(h.start, h.start)
            else
                ui:handleEvent(Event:new("GotoPage", h.page))
            end
        elseif o.kind == "percent" then
            ui:handleEvent(Event:new("GotoPercent", o.percent))
        elseif o.kind == "chapter" and o.xpointer and ui.rolling then
            ui.rolling:onGotoXPointer(o.xpointer)
        elseif o.page then
            ui:handleEvent(Event:new("GotoPage", o.page))
        end
    end)
end

---------------------------------------------------------------------------------------------------- gestures

function Ask:onTapOutside(_, ges)
    if self.kb_visible then
        -- a tap between the keys reaches us too: ignore it
        if ges.pos.y >= self.H - self:kbHeight() then return true end
    end
    if self.panel_region and ges.pos:intersectWith(self.panel_region) then
        if self.kb_visible then self:hideKeyboard() end
        return true
    end
    self:close()
    return true
end

function Ask:onSwipeSheet(_, ges)
    if self.kb_visible and ges.pos.y >= self.H - self:kbHeight() then return true end
    if ges.direction == "south" then
        if self.kb_visible then self:hideKeyboard() else self:close() end
    elseif ges.direction == "west" then
        self:turn(1)
    elseif ges.direction == "east" then
        self:turn(-1)
    end
    return true
end

-- Closing (here, or by the plugin when another sheet opens): stop work, put the keyboard away.
function Ask:teardown()
    if self.closed then return end
    self.closed = true
    self:cancelAll()
    if self.input then pcall(function() self.input:onCloseKeyboard() end) end
    if self.on_close then pcall(self.on_close) end
end

function Ask:handleEvent(ev)
    if ev.handler == "onCloseWidget" then self:teardown() end
    return Sheet.handleEvent(self, ev)
end

function Ask:close()
    self:teardown()
    Sheet.close(self)
end

---------------------------------------------------------------------------------------------------- entry

local M = { SUGGESTIONS = SUGGESTIONS }

function M.show(plugin, ui, opts)
    opts = opts or {}
    if plugin.sheet then plugin:closeSheet(plugin.sheet) end
    local ok, s = pcall(function()
        return Ask:new{ plugin = plugin, ui = ui, focus_text = opts.focus_text, focus_page = opts.focus_page,
            on_close = opts.on_close }
    end)
    if not ok then
        logger.warn("quiet ask: sheet failed:", s)
        return nil
    end
    plugin.sheet = s
    UIManager:show(s, "ui")
    local keyboard = opts.keyboard
    if keyboard == nil then keyboard = not (opts.focus_text or opts.suggest or opts.query) end
    if opts.suggest then
        s:runSuggestion(opts.suggest)
    elseif opts.query and opts.query ~= "" then
        s.input:setText(opts.query)
        s:submit(opts.query)
    elseif keyboard then
        s:showKeyboard()
    end
    return s
end

return M
