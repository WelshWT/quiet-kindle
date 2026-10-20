--[[
The four looks and the text-size steps, from the typography research (docs/design.md, "Reading text"):
Bookerly x-height 0.511 em; KOReader size N -> em px = ceil(N x 2.12) on the Paperwhite 12.
  Standard 22: x-height 2.0 mm (0.33 deg at 35 cm), 1.45 line height, 4.5 mm sides, justified
  Compact  20: 1.86 mm, 1.33 line height, 2.7 mm sides, justified          (+35-40% words per page)
  Relaxed  25: 2.29 mm, 1.6 line height, 5.4 mm sides, left aligned        (tired eyes, dense non-fiction)
  Bold     22: Standard + font weight +0.5 and contrast (gamma) 1.45       (dim light, fatigue)
Line spacing % multiplies the 1.45 em set by the "normal line height" style tweak.
]]

local Event = require("ui/event")

local L = {}

L.order = { "standard", "compact", "relaxed", "bold" }
L.names = { standard = "Standard", compact = "Compact", relaxed = "Relaxed", bold = "Bold" }

L.defs = {
    standard = { size = 22, line = 100, h = { 25, 25 }, t = 15, b = 15, weight = 0, gamma = 15, left = false },
    compact = { size = 20, line = 92, h = { 15, 15 }, t = 10, b = 10, weight = 0, gamma = 15, left = false },
    relaxed = { size = 25, line = 110, h = { 30, 30 }, t = 20, b = 20, weight = 0, gamma = 15, left = true },
    bold = { size = 22, line = 100, h = { 25, 25 }, t = 15, b = 15, weight = 0.5, gamma = 25, left = false },
}

-- Text sizes offered by the A/A buttons (KOReader units). 22 is Standard.
L.steps = { 18, 19, 20, 22, 24, 26, 29, 33 }

-- The Layout tab, Kindle's Aa > Layout (asked 20 Oct: "as many [options] as there are in the native Kindle reader,
-- like being able to mess with margins and font"): three margins, three line spacings and two alignments, as
-- Amazon's are. Normal is the research default (Standard's); Wide is Amazon's reader on a Paperwhite (~13 mm sides,
-- measured from screenshots); the other steps are the Compact and Relaxed looks' values.
L.MARGINS = {
    { id = "narrow", name = "Narrow", h = { 15, 15 }, t = 10, b = 10 },
    { id = "normal", name = "Normal", h = { 25, 25 }, t = 15, b = 15 },
    { id = "wide", name = "Wide", h = { 70, 70 }, t = 20, b = 20 },
}
L.SPACING = {
    { id = "tight", name = "Tight", line = 92 },
    { id = "normal", name = "Normal", line = 100 },
    { id = "loose", name = "Loose", line = 110 },
}
L.ALIGN = {
    { id = "justified", name = "Justified", left = false },
    { id = "left", name = "Left", left = true },
}

-- Kindle's eight reading fonts in Amazon's order: the name KOReader knows each by on the Paperwhite (its system
-- fonts, listed there 20 Oct) and the name Amazon's Aa menu shows. The Text tab offers the ones this Kindle has.
L.FONTS = {
    { face = "Bookerly", label = "Bookerly" },
    { face = "PMN Caecilia LT", label = "Caecilia" },
    { face = "Baskerville", label = "Baskerville" },
    { face = "Palatino", label = "Palatino" },
    { face = "Helvetica Neue LT 65 Kindle Medium", label = "Helvetica" },
    { face = "Futura Medium", label = "Futura" },
    { face = "Amazon Ember", label = "Amazon Ember" },
    { face = "OpenDyslexic", label = "OpenDyslexic" },
}

function L.current()
    return G_reader_settings:readSetting("quiet_look") or "standard"
end

local function same(a, b)
    if type(a) == "table" and type(b) == "table" then return a[1] == b[1] and a[2] == b[2] end
    return a == b
end

-- KOReader announces each change with a toast ("Font size set to: 24."); the toast is a widget that eats the
-- next tap, so a second press of A would do nothing. The page itself shows the change, so stay quiet.
local function quietly(fn)
    local Notification = require("ui/widget/notification")
    local orig = Notification.notify
    Notification.notify = function() end
    local ok, err = pcall(fn)
    Notification.notify = orig
    if not ok then error(err) end
end

local function setOption(ui, name, value, event)
    ui:handleEvent(Event:new("ConfigChange", name, value))
    if event then ui:handleEvent(Event:new(event, value)) end
    G_reader_settings:saveSetting("copt_" .. name, value)
end

function L.setSize(ui, size)
    if not ui.document then return end
    quietly(function() setOption(ui, "font_size", size, "SetFontSize") end)
end

function L.currentSize(ui)
    local conf = ui.document and ui.document.configurable
    return (conf and conf.font_size) or G_reader_settings:readSetting("copt_font_size") or 22
end

-- The fields of a look (or of one Layout step) and the KOReader option each one sets, in the order they're set.
local OPTIONS = {
    { "size", "font_size", "SetFontSize" },
    { "line", "line_spacing", "SetLineSpace" },
    { "h", "h_page_margins", "SetPageHorizMargins" },
    { "t", "t_page_margin", "SetPageTopMargin" },
    { "b", "b_page_margin", "SetPageBottomMargin" },
    { "weight", "font_base_weight", "SetFontBaseWeight" },
    { "gamma", "font_gamma", "SetFontGamma" },
}

-- Sets what `d` has (any of the fields above, and `left`) on the book and as every book's default. KOReader
-- re-lays out the book after each option; only what differs is set, all inside one BatchedUpdate, so the book is
-- re-laid out once, on the tick after this one (a sheet shows the new selection first).
local function applyFields(ui, d)
    local conf = ui.document.configurable
    quietly(function()
        ui:handleEvent(Event:new("BatchedUpdate"))
        local ok, err = pcall(function()
            for _, o in ipairs(OPTIONS) do
                local v = d[o[1]]
                if v ~= nil then
                    if same(conf[o[2]], v) then
                        G_reader_settings:saveSetting("copt_" .. o[2], v)
                    else
                        setOption(ui, o[2], v, o[3])
                    end
                end
            end
            -- Left alignment is a global style tweak; a per-book override would keep one book out of it.
            local st = ui.styletweak
            if st and d.left ~= nil then
                local was = st:isTweakEnabled("text_align_most_left")
                st.doc_tweaks.text_align_most_left = nil
                st.global_tweaks.text_align_most_left = d.left or nil
                G_reader_settings:saveSetting("style_tweaks", st.global_tweaks)
                if was ~= d.left then st:updateCssText(true) end
            end
        end)
        ui:handleEvent(Event:new("BatchedUpdateDone"))
        if not ok then error(err) end
    end)
end

-- A look touches up to seven settings and the alignment.
function L.apply(ui, id)
    local d = L.defs[id]
    if not d or not ui.document then return end
    applyFields(ui, d)
    G_reader_settings:saveSetting("quiet_look", id)
end

local function leftAligned(ui)
    return (ui.styletweak and ui.styletweak:isTweakEnabled("text_align_most_left")) and true or false
end

-- The look the book is set to now, or "custom" once margins, spacing or alignment were picked by hand. The size
-- doesn't count: it is changed all the time, and a look only starts from its size.
function L.matchLook(ui)
    local conf = ui.document and ui.document.configurable
    if not conf then return L.current() end
    local left = leftAligned(ui)
    for _, id in ipairs(L.order) do
        local d = L.defs[id]
        if same(conf.line_spacing, d.line) and same(conf.h_page_margins, d.h) and same(conf.t_page_margin, d.t)
            and same(conf.b_page_margin, d.b) and same(conf.font_base_weight, d.weight)
            and same(conf.font_gamma, d.gamma) and left == d.left then
            return id
        end
    end
    return "custom"
end

-- One step from the Layout tab (an entry of L.MARGINS, L.SPACING or L.ALIGN).
function L.setLayout(ui, step)
    if not ui.document then return end
    applyFields(ui, step)
    G_reader_settings:saveSetting("quiet_look", L.matchLook(ui))
end

-- Which step of a Layout row the book is on, or nil when it's between them (a look's own value).
function L.currentStep(ui, row)
    local conf = ui.document and ui.document.configurable
    if not conf then return nil end
    for _, s in ipairs(row) do
        if s.h and same(conf.h_page_margins, s.h) then return s.id end
        if s.line and same(conf.line_spacing, s.line) then return s.id end
        if s.left ~= nil and leftAligned(ui) == s.left then return s.id end
    end
end

-- Fonts -------------------------------------------------------------------------------------------------------------

function L.availableFonts()
    local have = {}
    local ok, FontList = pcall(require, "fontlist")
    if ok and type(FontList.fontinfo) == "table" then
        for _, info in pairs(FontList.fontinfo) do
            if info[1] and info[1].name then have[info[1].name] = true end
        end
    end
    local out = {}
    for _, f in ipairs(L.FONTS) do
        if have[f.face] then out[#out + 1] = f end
    end
    return out
end

function L.currentFont(ui)
    return (ui.font and ui.font.font_face) or G_reader_settings:readSetting("cre_font") or "Bookerly"
end

-- The font for this book and every book (Kindle's font choice is one for all books, as Quiet's text settings are).
function L.setFont(ui, face)
    if not (ui.document and ui.font) then return end
    quietly(function() ui.font:onSetFont(face) end)
    G_reader_settings:saveSetting("cre_font", face)
end

-- What the Text sheet sets is one set for every book, as on a Kindle: these aren't kept per book (main.lua drops
-- them from a book's settings when it closes, after KOReader saved them), so the next book opens with them.
L.GLOBAL_KEYS = { "font_face", "copt_font_size", "copt_line_spacing", "copt_h_page_margins", "copt_t_page_margin",
    "copt_b_page_margin", "copt_font_base_weight", "copt_font_gamma" }

return L
