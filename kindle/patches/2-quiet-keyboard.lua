--[[
Quiet keyboard: the Kindle's own keyboard, inside KOReader. Asked for: "the keyboard/typing is really buggy, slow,
and weird. please use REA to just copy the native kindle keyboard behavior or just have that be our keyboard", and
"not just have the same behavior but maximize performance and reliability".

Amazon's keyboard itself can't be borrowed: /usr/bin/kb is a GTK window that types into X11 programs, while
KOReader paints the framebuffer and reads the touch screen itself. So this is a copy, built from what every Kindle
ships and from libkb's code (read with REA on 22 Oct 2026, fw 5.19.6):
  - the layout is the Kindle's own keymap for this screen, /usr/share/keyboard/en_US/en_US-<w>x<h>.keymap.gz, read
    at run time (nothing of Amazon's is copied into this repo): three rows of letters and 123 · space · . · return
    under them, pages for Shift, Caps lock, 123 and #~=, and the accent rows a hold opens. Its key icons come from
    /usr/share/keyboard/images the same way.
  - the look is libkb's: white, keys without frames, labels in Amazon Ember at the size libkb asks for ("dialog 11"
    at the screen's dpi), the space bar a thin box. A pressed key gets a 4 px black frame.
  - a key lights when the finger lands and types when it lifts. Sliding moves the light; the key under the finger
    when it lifts is typed, unless the lift slipped onto the next key within 300 ms of the touch (less than a key's
    width sideways and half its height up or down): then the key first touched is. A second finger landing while
    the first is down types both, in the order they landed, when the first one lifts.
  - holding a key for 400 ms: accents (a c d e i n o s u y and their capitals; " ! ? * < > =) in a row above the
    keyboard: slide onto one and lift, or lift and tap one. Backspace repeats: every 400 ms, every 200 ms after four,
    and whole words after ten.
  - Shift: one capital, then lower case again; Shift again for Caps lock; again for lower case.
Faster than both: KOReader's keyboard showed a key only after the lift, for 15 ms. Here the frame is drawn straight
to the screen when the finger lands, as four A2 strips (only the frame: the label's grey edges never go through A2),
before the text update that follows on the lift. Return runs the field's action at once (KOReader waits 0.3 s).
Showing and hiding the keyboard no longer flashes.
More reliable than the Kindle's: a touch is a new one only with a new tracking id, so one finger never types twice;
a touch between keys goes to the nearest key (libkb ignores it); the light follows a sliding finger only once it is
1 mm past the key's edge.

Typed text without the flash. Asked for: "the box would flash sometimes, like the typing box". KOReader redraws a
field with its "ui" update, which on this Kindle is AUTO: the controller picks GC16 for text with grey edges, and
GC16 flashes every pixel it changes (most when a hint or a whole word goes). Text typed here goes out as DU instead
(no flash, no waiting), and once typing pauses for a second one REAGL update (Amazon's reading waveform, also
without a flash) gives the letters their smooth edges back.

Word suggestions and corrections (change 033). Asked for: "lightweight but accurate autocorrect ... Does Amazon have
that already? Can you just take that?", "or at least like word suggestions in the top row", then "it feels like the
autocorrect is barely funcitnal ... port in via understanding an open source or SOTA on device autocorrect that is not
resource intensive at all ... make it good like on google keyboard". Amazon's own engine (Nuance XT9, which its
keyboard uses) came first and was given up: it sees only which keys were typed, never where the finger landed, and
makes no corrections of its own. Now a decoder built as Google describes Gboard's (patches/quiet-decoder.lua) decides:
each tap counts against every key by its distance from the key's centre, letters left out or extra and swapped taps
cost a little, and each word by how common it is in AOSP's keyboard word list (US and British, 165,000 words,
data/quiet-keyboard/en.words.gz). It runs in a process of its own (patches/quiet-words.lua) with the list mapped from
a cache it builds once: ~3 MB, ~6 ms a word on this Kindle.
  - a row of up to three words above the keys, the likeliest in the middle, drawn once typing pauses (0.3 s; libkb
    waits 0.45 s); a tap types that word and a space
  - when another word is clearly likelier than what was typed, it is in bold in the middle and the space (or
    . , ? ! : ; or return) types it instead; the left word, in quotes, keeps what was typed. As careful as Gboard:
    a real word, or one of four letters or fewer ("rn", "omg", "idk"), changes only for a slip onto a neighbouring
    key or two swapped letters; a word typed with a capital costs little to keep (names); acronyms keep the case typed.
    Never for words of the book open in Search & Ask (quiet_ask.lua collects them), words in the names of the books
    on the Kindle, words put back before, nor unknown words typed twice without a correction (the user's own now)
  - backspace right after a correction puts back what was typed, and that word is never corrected again
    (quiet_keyboard_keep, the last 300)
On simulated typing with 9% of taps on a neighbouring key (tools/keyboard-eval), 62% of words come out right as typed
and 92% after correction; no right word is changed.
Not for passwords or number fields.

Only touches that begin on the keyboard while it is the top window there are taken; all others go to KOReader's
gestures as before. KOReader's own keyboard stays where there is no keymap for the screen (other devices) or the
keyboard language isn't English, and everywhere when quiet_keyboard is off (change 032; undo it to switch back).
]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InputText = require("ui/widget/inputtext")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VirtualKeyboard = require("ui/widget/virtualkeyboard")
local bit = require("bit")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local rapidjson = require("rapidjson")
local time = require("ui/time")
local util = require("util")
local C = ffi.C
local Screen = Device.screen
require("ffi/posix_h")

local KB_DIR = "/usr/share/keyboard/"
local LANG = "en_US"
local HOLD_S = 0.4         -- libkb's repeat_ms_threshold1: accents, and backspace's first repeats
local REPEAT_FAST_S = 0.2  -- repeat_ms_threshold2
local REPEAT_SLOW_N = 4    -- repeat_count_threshold2: repeats at the slow pace before the fast one
local WORD_AFTER_N = 10    -- backspace deletes whole words after this many repeats, at the slow pace
local UNPRESS_S = 0.05     -- the frame stays this long after the lift
local SLIP_MS = 300
local FRAME_BW = 4
local RETURN = "\u{FF0D}"  -- the keymap's value for the return key
local BAR_DELAY_S = 0.3    -- suggestions are drawn once typing pauses this long
local SMOOTH_S = 2.0       -- typed text (DU) is redrawn smooth (REAGL, which holds KOReader ~0.2 s) after this pause
local FIX_WAIT_S = 0.15    -- how long a space waits for the decoder before typing on uncorrected
local COMPLETE_LEAD = 4.0  -- a word not finished yet: the likeliest word it starts goes in the middle of the row unless
                           -- another is this much likelier (nats; "keyb": keyboard, not key)
local KEEP_MAX = 300       -- words put back after a correction, remembered
local ENDS = { ["."] = true, [","] = true, ["?"] = true, ["!"] = true, [":"] = true, [";"] = true }

local INK = Blitbuffer.COLOR_BLACK
local PAPER = Blitbuffer.COLOR_WHITE
local LINE = Blitbuffer.gray(0.35) -- the line above the keyboard, as Quiet's outlines

-- where this file is: the words helper sits next to it
local HERE = ((debug.getinfo(1, "S").source or ""):match("^@(.*/)") or "patches/"):gsub("^%./", "")

---------------------------------------------------------------------------------------------------- the keymap

-- Which layouts make each page (libkb's layout types): the letters, the Shift key's state, the bottom row.
local PAGES = {
    lower = { 16, 1 },
    shift = { 96, 32, 1 },
    lock = { 96, 64, 1 },
    num1 = { 33554560, 128, 4 }, -- the web variant (33554432: × ÷ for / @) is for address fields
    num2 = { 67109120, 4 },
}
local ACCENTS = 8192

local function fontPx(desc, dpi)
    -- a pango description like "dialog 11" or "dialog bold 6": size in points
    local pt = tonumber((desc or ""):match("(%d+%.?%d*)%s*$")) or 11
    return math.floor(pt * dpi / 72 + 0.5), (desc or ""):find("bold") ~= nil
end

local function faceFor(px, bold)
    local f = Screen:scaleBySize(1000) / 1000 -- Font:getFace scales by screen size itself
    return Font:getFace(bold and "Amazon-Ember-Bold.ttf" or "Amazon-Ember-Regular.ttf", math.max(6, math.floor(px / f + 0.5)))
end

local function readKeymap(w, h)
    local path = string.format("%s%s/%s-%dx%d.keymap.gz", KB_DIR, LANG, LANG, w, h)
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local p = io.popen("zcat '" .. path .. "' 2>/dev/null") -- the path is made of constants and numbers
    if not p then return nil end
    local s = p:read("*a")
    p:close()
    local ok, t = pcall(rapidjson.decode, s)
    if not ok or type(t) ~= "table" or type(t.layouts) ~= "table" then
        logger.warn("quiet keyboard: can't read", path)
        return nil
    end
    return t
end

-- A key as the keyboard uses it: its box in keyboard coordinates, what it shows and what it does.
local function makeKey(k, L, map, dpi)
    local key = {
        x = k.x, y = k.y, w = k.width or L.width, h = k.height or L.height,
        label = k.label or "", value = k.value, hold = k.hold,
    }
    if type(key.w) ~= "number" or type(key.h) ~= "number" or type(key.x) ~= "number" or type(key.y) ~= "number" then
        return nil
    end
    local v = key.value
    if type(v) == "string" and v:sub(1, 2) == "!!" then
        key.cmd = v:sub(3)
    elseif v == " " then
        key.cmd, key.space = "space", true
    elseif v == RETURN then
        key.cmd = "return"
    end
    if key.label:sub(1, 7) == "file://" then
        key.icon = key.label:sub(8)
    elseif not key.cmd then
        key.text = key.label ~= "" and key.label or v -- capitals' accents carry a lower-case value: the label is it
    end
    key.px, key.bold = fontPx(k.font or L.font, dpi)
    -- the frame a press draws, libkb's: inset by the keymap's gaps; the space bar's by its own box
    local gx, gy = map.keyboard_x_gap or 7, map.keyboard_y_gap or 8
    if key.space then
        local oy = k.alt_offset_y or k.offset_y or gy
        key.frame = { x = key.x + gx + 1, y = key.y + oy + 2, w = key.w - 2 * gx - 2, h = key.h - 2 * oy - 4 }
    else
        key.frame = { x = key.x + gx + 1, y = key.y + gy, w = key.w - 2 * gx - 2, h = key.h - 2 * gy }
    end
    return key
end

local Keymaps = {} -- "WxH" -> parsed keymap, or false when the Kindle has none for that screen

local function keymap(W, H)
    local id = W .. "x" .. H
    if Keymaps[id] == nil then
        local map = readKeymap(W, H)
        if not map then
            Keymaps[id] = false
        else
            local dpi = Screen:getDPI()
            local by_type, accents = {}, {}
            for _, L in ipairs(map.layouts) do
                local keys = {}
                for _, k in ipairs(L.keys or {}) do keys[#keys + 1] = makeKey(k, L, map, dpi) end
                if L.type == ACCENTS and L.diacritical then
                    accents[L.diacritical] = keys
                elseif L.type then
                    by_type[L.type] = by_type[L.type] or keys -- the first of a type wins, as in libkb's lookups
                end
            end
            local pages = {}
            for name, types in pairs(PAGES) do
                local keys = {}
                for _, t in ipairs(types) do
                    for _, k in ipairs(by_type[t] or {}) do keys[#keys + 1] = k end
                end
                pages[name] = keys
            end
            local ok = #pages.lower > 20 and #pages.num1 > 20
            Keymaps[id] = ok and {
                pages = pages, accents = accents, bb = {},
                height = math.min(map.keyboard_height or 497, H),
                -- the suggestion row: libkb's candidate bar, as high and in the same font
                bar_h = map.candidate_height or 80,
                bar_px = fontPx(map.candidate_font, dpi),
                gx = map.keyboard_x_gap or 7, gy = map.keyboard_y_gap or 8,
            } or false
        end
    end
    return Keymaps[id] or nil
end

---------------------------------------------------------------------------------------------------- drawing

local Icons = {} -- path -> blitbuffer (or false)

local function icon(path)
    if Icons[path] == nil then
        local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, path)
        Icons[path] = ok and bb or false
    end
    return Icons[path] or nil
end

local function drawLabel(bb, key, ox, oy)
    local cx, cy = ox + key.x, oy + key.y
    if key.icon then
        local img = icon(key.icon)
        if img then
            local iw, ih = img:getWidth(), img:getHeight()
            local x, y = cx + math.floor((key.w - iw) / 2), cy + math.floor((key.h - ih) / 2)
            local t = img:getType()
            if t == Blitbuffer.TYPE_BB8A or t == Blitbuffer.TYPE_BBRGB32 then
                bb:alphablitFrom(img, x, y, 0, 0, iw, ih)
            else
                bb:blitFrom(img, x, y, 0, 0, iw, ih)
            end
            return
        end
    end
    local text = key.text or (key.space and "SPACE") or (key.cmd == "back" and "⌫") or (key.cmd == "return" and "⏎")
        or (key.cmd == "shift" and "⇧") or (key.cmd == "lower" and "⇪") or key.label
    if key.space then
        local f = key.frame
        bb:paintBorder(ox + f.x, oy + f.y, f.w, f.h, 2, INK)
    end
    if not text or text == "" then return end
    local tw = TextWidget:new{ text = text, face = faceFor(key.px, key.bold), fgcolor = INK, padding = 0 }
    local s = tw:getSize()
    tw:paintTo(bb, cx + math.floor((key.w - s.w) / 2), cy + math.floor((key.h - s.h) / 2))
    tw:free()
end

local function pageBB(km, name, W)
    if not km.bb[name] then
        local bb = Blitbuffer.new(W, km.height, Screen.bb:getType())
        bb:fill(PAPER)
        bb:paintRect(0, 0, W, 2, LINE)
        for _, key in ipairs(km.pages[name]) do drawLabel(bb, key, 0, 0) end
        km.bb[name] = bb
    end
    return km.bb[name]
end

-- Only black and white left: what changes by DU (or A2) has no grey to lose, so it looks the same once it's up.
local function blackAndWhite(bb)
    if bb:getType() ~= Blitbuffer.TYPE_BB8 then return end
    local data = ffi.cast("uint8_t *", bb.data)
    local stride = tonumber(bb.stride)
    for y = 0, bb:getHeight() - 1 do
        local row = data + y * stride
        for x = 0, bb:getWidth() - 1 do
            row[x] = row[x] < 128 and 0 or 255
        end
    end
end

-- The four sides of a key's frame, in screen coordinates: they never overlap, so each is its own A2 update.
local function strips(f, ox, oy)
    local x, y, w, h, b = ox + f.x, oy + f.y, f.w, f.h, FRAME_BW
    return {
        { x, y, w, b }, { x, y + h - b, w, b },
        { x, y + b, b, h - 2 * b }, { x + w - b, y + b, b, h - 2 * b },
    }
end

---------------------------------------------------------------------------------------------------- the keyboard

local shown = setmetatable({}, { __mode = "k" }) -- keyboards on screen now

-- Timer work runs inside UIManager's loop, where an error would take KOReader down with the book open: log it instead.
local function safely(fn)
    return function()
        local ok, err = pcall(fn)
        if not ok then logger.warn("quiet keyboard:", err) end
    end
end

local function inBox(x, y, b)
    return x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h
end

local function overlap(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

---------------------------------------------------------------------------------------------------- the words helper

--[[ The words helper (patches/quiet-words.lua) and what it has answered. A question is a token: the word before the
cursor (accents dropped), where each of its letters was tapped, and whether it is one of the user's own words.
ask(token) sends it on its way (answers come back between keys: a check every 20 ms while one is due), answer(token)
is the answer if it's there, wait(token, s) waits for it at most s seconds (a space, deciding whether to correct).
The helper starts 8 s after KOReader and runs until KOReader ends. It says when its words are in (the very first
start builds a cache of the list: a few seconds); from then on a question left unanswered for 3 s means it is stuck,
and it is stopped (and started again on the next word). Three failures and it stays off for the session. ]]
local Suggest = { buf = "", seq = 0, asked = {}, answers = {}, order = {}, fails = 0, retry_at = 0 }

local function absolute(path) return path:sub(1, 1) == "/" and path or lfs.currentdir() .. "/" .. path end
local HELPER = absolute(HERE .. "quiet-words.lua")
local LUAJIT = absolute("luajit")
local WORDS = absolute("data/quiet-keyboard/en.words.gz")
local CACHE = absolute(DataStorage:getDataDir() .. "/cache/quiet-keyboard-words.bin")

function Suggest.available()
    return lfs.attributes(WORDS, "mode") == "file" and lfs.attributes(HELPER, "mode") == "file"
        and lfs.attributes(LUAJIT, "mode") == "file"
end

-- A killed helper, collected once it's gone, however long that takes (a kill lands only after uninterruptible
-- storage I/O): never a zombie. Checked less and less often.
local function reap(pid)
    local wait = 0.5
    local check
    check = function()
        if not ffiutil.isSubProcessDone(pid) then
            wait = math.min(wait * 2, 30)
            UIManager:scheduleIn(wait, check)
        end
    end
    UIManager:scheduleIn(wait, check)
end

function Suggest.stop(why)
    if why then logger.warn("quiet keyboard: suggestions stopped:", why) end
    if Suggest.rfd then C.close(Suggest.rfd) end
    if Suggest.wfd then C.close(Suggest.wfd) end
    local pid = Suggest.pid
    Suggest.pid, Suggest.rfd, Suggest.wfd, Suggest.buf, Suggest.asked = nil, nil, nil, "", {}
    Suggest.ready, Suggest.keys_for = false, nil
    if pid then
        C.kill(pid, 9)
        reap(pid)
    end
    if why then
        Suggest.fails = Suggest.fails + 1
        Suggest.retry_at = os.time() + 10
    end
end

function Suggest.start()
    if Suggest.pid then return true end
    if Suggest.fails >= 3 or os.time() < Suggest.retry_at or not Suggest.available() then return false end
    local luajit, helper, words, cache = LUAJIT, HELPER, WORDS, CACHE
    local pid, rfd, wfd = ffiutil.runInSubProcess(function(_, child_w, child_r)
        -- background work is niced and batch-scheduled there; this answers keys, so it gets KOReader's own priority
        -- (the helper lowers its own while it loads)
        pcall(function()
            C.sched_setscheduler(0, 0, ffi.new("struct sched_param")) -- 0: SCHED_OTHER
            C.setpriority(C.PRIO_PROCESS, 0, 0)
        end)
        C.dup2(child_r, 0)
        C.dup2(child_w, 1)
        for fd = 3, 1023 do C.close(fd) end -- nothing of KOReader's (screen, input, sockets) goes with it
        C.execl(luajit, luajit, helper, words, cache, nil)
    end, "bidi")
    if not pid then
        Suggest.fails = Suggest.fails + 1
        Suggest.retry_at = os.time() + 10
        logger.warn("quiet keyboard: no suggestions:", rfd)
        return false
    end
    -- fcntl's third argument is variadic: a plain Lua number would go as a double (on ARM, into the wrong
    -- registers), so these are C ints. Reads and writes don't rely on them anyway: they wait on poll() first.
    for _, fd in ipairs({ rfd, wfd }) do
        C.fcntl(fd, C.F_SETFL, ffi.new("int", bit.bor(C.fcntl(fd, C.F_GETFL, ffi.new("int", 0)), C.O_NONBLOCK)))
        C.fcntl(fd, C.F_SETFD, ffi.new("int", C.FD_CLOEXEC)) -- not handed on to programs KOReader starts later
    end
    Suggest.pid, Suggest.rfd, Suggest.wfd, Suggest.buf = pid, rfd, wfd, ""
    Suggest.ready, Suggest.started_at, Suggest.keys_for = false, time.now(), nil
    Suggest.watch() -- for its "ready"
    return true
end

local readbuf = ffi.new("char[4096]")
local pfd = ffi.new("struct pollfd[1]")

-- Whether fd can be read (POLLIN) or written (POLLOUT) within ms: the only waits on the helper, all bounded, so a
-- stuck helper can cost a suggestion but never hold KOReader up.
local function ready(fd, events, ms)
    pfd[0].fd, pfd[0].events, pfd[0].revents = fd, events, 0
    return C.poll(pfd, 1, ms) > 0
end

-- One line to the helper, whole or not at all: a line is shorter than PIPE_BUF, which a pipe takes in one write once
-- poll() says it has room.
function Suggest.send(line)
    if not Suggest.wfd or not ready(Suggest.wfd, C.POLLOUT, 0) then return false end -- behind: this one goes unsaid
    if tonumber(C.write(Suggest.wfd, line, #line)) ~= #line then
        Suggest.stop("can't write to the helper")
        return false
    end
    return true
end

-- The letter keys' centres, which taps are scored against, in keyboard coordinates (from the rows' top left) as the
-- taps are sent; again when another keymap shows.
function Suggest.keys(km)
    if Suggest.keys_for == km then return true end
    local list, kw, kh = {}, nil, nil
    for _, k in ipairs(km.pages.lower) do
        if k.text and k.text:find("^%l$") then
            list[#list + 1] = string.format("%s:%.1f,%.1f", k.text, k.x + k.w / 2, k.y + k.h / 2)
            kw, kh = kw or k.w, kh or k.h
        end
    end
    if not kw or not Suggest.send(string.format("K\t%.1f\t%.1f\t%s\n", kw, kh, table.concat(list, ";"))) then
        return false
    end
    Suggest.keys_for = km
    return true
end

function Suggest.answer(token)
    return Suggest.answers[token]
end

local function remember(token, r)
    if not Suggest.answers[token] then
        Suggest.order[#Suggest.order + 1] = token
        if #Suggest.order > 32 then Suggest.answers[table.remove(Suggest.order, 1)] = nil end
    end
    Suggest.answers[token] = r
end

-- "ID\tFIX\tVALID\tCOST\tWORD:COST[+]\t...": the correction a space would type (or none), whether the word as typed is
-- one, what keeping it costs, and the likeliest words (+: a completion), best first.
local function parse(line)
    local f = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = field end
    local r = { fix = f[2] ~= "" and f[2] or nil, valid = f[3] == "1", cost = tonumber(f[4]), cands = {} }
    for i = 5, #f do
        local w, c, more = f[i]:match("^(.+):(%-?[%d.]+)(%+?)$")
        if w then r.cands[#r.cands + 1] = { word = w, cost = tonumber(c), completion = more == "+" } end
    end
    return r
end

-- Whatever the helper has said since last time; keyboards waiting for one of those answers get it.
function Suggest.drain()
    while Suggest.rfd and ready(Suggest.rfd, C.POLLIN, 0) do
        local n = tonumber(C.read(Suggest.rfd, readbuf, 4096))
        if n and n > 0 then
            Suggest.buf = Suggest.buf .. ffi.string(readbuf, n)
        elseif n and n < 0 and ffi.errno() == C.EAGAIN then
            break
        else
            return Suggest.stop(n == 0 and "the helper ended" or "can't read the helper")
        end
    end
    if not Suggest.rfd then return end
    local answered = {}
    for line in Suggest.buf:gmatch("([^\n]*)\n") do
        if line:sub(1, 2) == "R\t" then
            Suggest.ready = true
            Suggest.asked_at = time.now() -- questions sent while it was loading: their 3 s start now
            logger.info("quiet keyboard: words ready:", line:sub(3))
        else
            local id = tonumber(line:match("^(%d+)\t"))
            local token = id and Suggest.asked[id]
            if token then
                remember(token, parse(line))
                answered[#answered + 1] = token
                for k in pairs(Suggest.asked) do -- older questions are never answered: the helper skips past them
                    if k <= id then Suggest.asked[k] = nil end
                end
            end
        end
    end
    Suggest.buf = Suggest.buf:match("[^\n]*$")
    for _, token in ipairs(answered) do
        for kb in pairs(shown) do kb:answered(token) end
    end
end

function Suggest.watch()
    if Suggest.watching then return end
    Suggest.watching = true
    local tick
    tick = safely(function()
        Suggest.drain()
        local again
        if not Suggest.pid then
            again = nil
        elseif not Suggest.ready then
            if time.to_ms(time.since(Suggest.started_at)) > 60000 then
                Suggest.stop("the helper didn't start")
            else
                again = 0.1
            end
        elseif next(Suggest.asked) then
            if time.to_ms(time.since(Suggest.asked_at)) > 3000 then
                Suggest.stop("the helper isn't answering")
            else
                again = 0.02
            end
        end
        if again then UIManager:scheduleIn(again, tick) else Suggest.watching = false end
    end)
    UIManager:scheduleIn(0.02, tick)
end

function Suggest.ask(token, km)
    if Suggest.answers[token] or not Suggest.start() or not Suggest.keys(km) then return end
    if Suggest.asked[Suggest.seq] == token then return end -- already the latest question
    local id = Suggest.seq + 1
    if not Suggest.send(id .. "\t" .. token .. "\n") then return end
    Suggest.seq = id
    Suggest.asked[id] = token
    Suggest.asked_at = time.now()
    Suggest.watch()
end

function Suggest.wait(token, km, secs)
    if Suggest.answers[token] then return Suggest.answers[token] end
    Suggest.ask(token, km)
    if Suggest.asked[Suggest.seq] ~= token then return nil end -- not asked: the helper is off, or behind
    local deadline = time.now() + time.s(secs)
    while not Suggest.answers[token] and Suggest.rfd do
        local left = time.to_ms(deadline - time.now())
        if left <= 0 or not ready(Suggest.rfd, C.POLLIN, math.ceil(left)) then break end
        Suggest.drain()
    end
    return Suggest.answers[token]
end

---------------------------------------------------------------------------------------------------- words

-- Letters (accented ones too) and apostrophes make words; Latin-1's × and ÷ don't.
local function wordChar(ch)
    if not ch then return false end
    if #ch == 1 then return ch:find("^[%a']$") ~= nil end
    local b = ch:byte(1)
    return #ch == 2 and b >= 0xC3 and b <= 0xC9 and ch ~= "×" and ch ~= "÷"
end

local function nchars(s)
    return select(2, s:gsub("[^\128-\191]", ""))
end

-- A word in a name or a book's text: letters (accented ones: their UTF-8 lead bytes are \195-\201) with apostrophes
-- inside. Curly quotes, dashes (\226...) and no-break spaces (\194\160) end it.
local WORD = "[%a\195-\201][%a'\128-\191\195-\201]*"

-- A word split into what the decoder sees and the apostrophes that close it (a quote mark, or dogs'): corrections and
-- suggestions leave those where they are.
local function splitTail(word)
    return word:match("^(.-)('*)$")
end

-- Accented letters are typed on their base letter's key, and the word list knows its words by their letters
-- without accents: é goes to the decoder as e, æ as ae (its words come back spelt with them).
local PLAIN = {}
for _, pair in ipairs({
    { "a", "àáâãäåā" }, { "A", "ÀÁÂÃÄÅĀ" }, { "c", "çćč" }, { "C", "ÇĆČ" }, { "d", "ď" }, { "D", "Ď" },
    { "e", "èéêëēėęě" }, { "E", "ÈÉÊËĒĖĘĚ" }, { "i", "ìíîïīį" }, { "I", "ÌÍÎÏĪĮ" }, { "l", "ł" }, { "L", "Ł" },
    { "n", "ñńň" }, { "N", "ÑŃŇ" }, { "o", "òóôõöøō" }, { "O", "ÒÓÔÕÖØŌ" }, { "s", "śšş" }, { "S", "ŚŠŞ" },
    { "u", "ùúûüūů" }, { "U", "ÙÚÛÜŪŮ" }, { "y", "ýÿ" }, { "Y", "ÝŸ" }, { "z", "źżž" }, { "Z", "ŹŻŽ" },
    { "ae", "æ" }, { "Ae", "Æ" }, { "oe", "œ" }, { "Oe", "Œ" }, { "ss", "ß" },
}) do
    for ch in pair[2]:gmatch("[\192-\244][\128-\191]*") do PLAIN[ch] = pair[1] end
end

local Keep -- lower-cased words put back after a correction, or typed twice as they were: never corrected again

local function keepSet()
    if not Keep then
        Keep = {}
        for _, w in ipairs(G_reader_settings:readSetting("quiet_keyboard_keep") or {}) do Keep[w] = true end
    end
    return Keep
end

local function keep(word)
    local w = word:lower()
    local set = keepSet()
    if set[w] then return end
    set[w] = true
    local list = G_reader_settings:readSetting("quiet_keyboard_keep") or {}
    table.insert(list, 1, w)
    while #list > KEEP_MAX do set[table.remove(list)] = nil end
    G_reader_settings:saveSetting("quiet_keyboard_keep", list)
end

-- Unknown words typed this session and left as they were: the second time, one of the user's own (as Gboard learns).
local Seen = {}

local function learn(word)
    local w = word:lower()
    Seen[w] = (Seen[w] or 0) + 1
    if Seen[w] >= 2 then keep(word) end
end

-- Lower-cased words (three letters or more) from the names of the books on the Kindle: titles and authors are what
-- the Library's search is for. Read once a session, starting a second after the first keyboard with suggestions
-- shows, from the folders' listings alone (no stat per file: this storage is slow at it), in slices of 20 ms between
-- whatever else KOReader does, 20,000 names at most: a book by its extension; a folder is a name without one (or
-- whose "extension" is part of a name: "L.M. Montgomery").
local Library
local BOOK = {}
for ext in ("epub pdf mobi azw azw3 kfx prc fb2 txt rtf djvu cbz cbr docx html htm chm"):gmatch("%S+") do BOOK[ext] = true end

local function libraryWords()
    if Library then return end
    Library = {}
    local home = G_reader_settings:readSetting("home_dir")
    if type(home) ~= "string" then return end
    local folders, names, cur = { { home, 1 } }, 0, nil -- cur: the folder being listed, its listing kept between slices
    local step
    step = safely(function()
        local t0 = time.now()
        while names < 20000 and time.to_ms(time.since(t0)) < 20 do
            if not cur then
                local f = table.remove(folders)
                if not f then break end
                local ok, iter, dir = pcall(lfs.dir, f[1])
                if ok then cur = { iter = iter, dir = dir, path = f[1], depth = f[2] } end -- else: not a folder
            else
                local name = cur.iter(cur.dir)
                if not name then
                    cur = nil
                else
                    names = names + 1
                    local ext = name:match("%.([^.]+)$")
                    local lext = ext and ext:lower()
                    local skip = name:sub(1, 1) == "." or lext == "sdr" -- hidden, or a book's settings
                    if not skip and lext and BOOK[lext] then
                        for w in name:sub(1, -#ext - 2):gmatch(WORD) do
                            if #w >= 3 then Library[w:lower()] = true end
                        end
                    elseif not skip and cur.depth < 4 and (not ext or #ext > 5 or ext:find("%s")) then
                        folders[#folders + 1] = { cur.path .. "/" .. name, cur.depth + 1 }
                    end
                end
            end
        end
        if names < 20000 and (cur or folders[1]) then
            UIManager:scheduleIn(0.05, step)
        elseif cur then
            pcall(cur.dir.close, cur.dir) -- stopped part-way through a folder
            cur = nil
        end
    end)
    step()
end

-- quiet_keyboard_log (off unless asked for, for tuning): every word that ended, what the decoder made of it and what
-- was done, in settings/quiet/keyboard.log (the last 256 KB, and one older file). It is what was typed: never in a
-- commit or anywhere else.
local LOG = DataStorage:getSettingsDir() .. "/quiet/keyboard.log"

local function logWord(fmt, ...)
    if not G_reader_settings:isTrue("quiet_keyboard_log") then return end
    local size = lfs.attributes(LOG, "size")
    if size and size > 256 * 1024 then os.rename(LOG, LOG .. ".1") end
    local f = io.open(LOG, "a")
    if not f then return end
    f:write(os.date("%Y-%m-%d %H:%M:%S "), string.format(fmt, ...), "\n")
    f:close()
end

---------------------------------------------------------------------------------------------------- the keyboard

local QuietKeyboard = VirtualKeyboard:extend{
    name = "QuietKeyboard",
}

function QuietKeyboard.available()
    return keymap(Screen:getWidth(), Screen:getHeight()) ~= nil
end

function QuietKeyboard:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local ib = self.inputbox
    self.km = keymap(W, H)
    self.suggest = ib ~= nil and G_reader_settings:isTrue("quiet_keyboard_suggest") and not ib.readonly
        and ib.text_type ~= "password" and not ib.is_password_type and ib.input_type ~= "number"
        and Suggest.available()
    local bar_h = self.suggest and self.km.bar_h or 0
    self.width, self.height = W, self.km.height + bar_h
    self.dimen = Geom:new{ x = 0, y = H - self.height, w = W, h = self.height }
    self.rows = Geom:new{ x = 0, y = H - self.km.height, w = W, h = self.km.height } -- the keys
    self.bar = self.suggest and Geom:new{ x = 0, y = self.dimen.y, w = W, h = bar_h } or nil -- the suggestions
    self.page = (ib and ib.input_type == "number") and "num1" or "lower"
    self.contacts = {}  -- fingers down on the keyboard, in the order they landed
    self.lit = {}       -- keys showing a frame
    self.popup = nil    -- the accent row, when open
    self.slots = {}     -- what the suggestion row shows
    self.taps = {}      -- the word before the cursor as typed: { ch, x, y } a character (x, y: where it was tapped)
    self.key_events = {}
    if self.bar then self:renderBar() end
end

function QuietKeyboard:getSize()
    return Screen:getSize()
end

function QuietKeyboard:keys()
    return self.km.pages[self.page]
end

function QuietKeyboard:rowsWhere()
    return { x = self.rows.x, y = self.rows.y }
end

function QuietKeyboard:paintTo(bb, x, y)
    local r = self.rows
    bb:blitFrom(pageBB(self.km, self.page, r.w), r.x, r.y, 0, 0, r.w, r.h)
    if self.bar and self.bar_bb then
        local b = self.bar
        bb:blitFrom(self.bar_bb, b.x, b.y, 0, 0, b.w, b.h)
        bb:paintRect(b.x, b.y, b.w, 2, LINE)
    end
    if self.popup then self:paintPopup(bb) end
    for key, where in pairs(self.lit) do
        for _, s in ipairs(strips(key.frame, where.x, where.y)) do bb:paintRect(s[1], s[2], s[3], s[4], INK) end
    end
end

-- The press frame, drawn on the screen right away (not at the next repaint), or taken away again.
function QuietKeyboard:light(key, on, where)
    if not self.visible then return end
    where = where or self:rowsWhere()
    if (where.popup and not self.popup) or (where.bar and not self.bar_bb) then
        self.lit[key] = nil
        return
    end
    if on then self.lit[key] = where else self.lit[key] = nil end
    local f = key.frame
    local rect = Geom:new{ x = where.x + f.x, y = where.y + f.y, w = f.w, h = f.h }
    if self:above(rect) then -- under another window: through a repaint, which keeps that window on top
        UIManager:setDirty(self, function() return "ui", rect end)
        return
    end
    local bb = Screen.bb
    local list = strips(key.frame, where.x, where.y)
    for _, s in ipairs(list) do
        if on then
            bb:paintRect(s[1], s[2], s[3], s[4], INK)
        elseif where.popup then
            bb:blitFrom(self.popup.bb, s[1], s[2], s[1] - self.popup.x, s[2] - self.popup.y, s[3], s[4])
        elseif where.bar then
            bb:blitFrom(self.bar_bb, s[1], s[2], s[1] - self.bar.x, s[2] - self.bar.y, s[3], s[4])
        else
            bb:blitFrom(pageBB(self.km, self.page, self.rows.w), s[1], s[2], s[1] - self.rows.x, s[2] - self.rows.y, s[3], s[4])
        end
    end
    local a2 = Screen.refreshA2 or Screen.refreshFast
    for _, s in ipairs(list) do a2(Screen, s[1], s[2], s[3], s[4]) end
end

function QuietKeyboard:setPage(name)
    if name == self.page or not self.km.pages[name] then return end
    self.page = name
    for key, where in pairs(self.lit) do
        if not where.popup and not where.bar then self.lit[key] = nil end
    end
    local rect = self.rows
    UIManager:setDirty(self, function() return "ui", rect end)
end

---------------------------------------------------------------------------------------------------- accents

function QuietKeyboard:openPopup(key)
    local keys = self.km.accents[key.hold]
    if not keys or #keys == 0 then return end
    self:closePopup()
    local x0, x1 = math.huge, 0
    for _, k in ipairs(keys) do x0, x1 = math.min(x0, k.x), math.max(x1, k.x + k.w) end
    local kh = keys[1].h
    local pad = 6
    local p = { base = key, keys = keys, armed = false }
    p.w, p.h = x1 - x0 + 2 * pad, kh + 2 * pad
    p.x = math.max(0, math.min(self.dimen.w - p.w, x0 - pad))
    p.y = math.max(0, self.rows.y - p.h + 15) -- its keys sit just above the first row, as libkb's do
    p.kx, p.ky = p.x + pad - x0, p.y + pad - keys[1].y -- keymap coordinates -> screen
    local bb = Blitbuffer.new(p.w, p.h, Screen.bb:getType())
    bb:fill(PAPER)
    bb:paintBorder(0, 0, p.w, p.h, 3, INK)
    for _, k in ipairs(keys) do drawLabel(bb, k, p.kx - p.x, p.ky - p.y) end
    p.bb = bb
    self.popup = p
    local rect = self:popupRect() -- now: the row may be gone again by the time the refresh runs
    UIManager:setDirty(self, function() return "ui", rect end)
end

function QuietKeyboard:popupRect()
    local p = self.popup
    return Geom:new{ x = p.x, y = p.y, w = p.w, h = p.h }
end

function QuietKeyboard:paintPopup(bb)
    local p = self.popup
    bb:blitFrom(p.bb, p.x, p.y, 0, 0, p.w, p.h)
end

function QuietKeyboard:closePopup()
    local p = self.popup
    if not p then return end
    local rect = self:popupRect()
    for key, where in pairs(self.lit) do
        if where.popup then self.lit[key] = nil end
    end
    self.popup = nil
    p.bb:free()
    if self.visible then
        UIManager:setDirty("all", function() return "ui", rect end) -- what was under the row comes back
    end
end

function QuietKeyboard:popupWhere()
    return { x = self.popup.kx, y = self.popup.ky, popup = true }
end

---------------------------------------------------------------------------------------------------- the suggestion row

function QuietKeyboard:barWhere()
    return { x = self.bar.x, y = self.bar.y, bar = true }
end

-- Draws self.slots (positions 1-3: left, middle, right) into the row's own buffer; each word is a key there.
function QuietKeyboard:renderBar()
    local b, km = self.bar, self.km
    local bb = self.bar_bb
    if not bb then
        bb = Blitbuffer.new(b.w, b.h, Screen.bb:getType())
        self.bar_bb = bb
    end
    bb:fill(PAPER)
    local sw = math.floor(b.w / 3)
    local keys = {}
    for i = 1, 3 do
        local e = self.slots[i]
        if e then
            local key = { x = (i - 1) * sw, y = 0, w = sw, h = b.h, cmd = "suggest", entry = e }
            key.frame = { x = key.x + km.gx + 1, y = km.gy, w = sw - 2 * km.gx - 2, h = b.h - 2 * km.gy }
            local tw = TextWidget:new{ text = e.label, face = faceFor(km.bar_px, e.bold), fgcolor = INK, padding = 0,
                max_width = sw - 2 * (km.gx + 16) }
            local s = tw:getSize()
            tw:paintTo(bb, key.x + math.floor((sw - s.w) / 2), math.floor((b.h - s.h) / 2))
            tw:free()
            keys[i] = key
        end
    end
    blackAndWhite(bb) -- the row changes by DU: no flash, and nothing grey for it to spoil
    self.bar_keys = keys
end

-- What the row offers for a word, from the decoder's answer: its likeliest words (each once, and not the word as typed)
-- and the correction a space would type, when corrections are on. Never for a word that is the user's own by now (the
-- library's names and the book's words come in while typing: the answer may predate them).
function QuietKeyboard:plan(word, r)
    local fix = G_reader_settings:isTrue("quiet_keyboard_autocorrect") and r.fix ~= word and not self:isKnown(word)
        and r.fix or nil
    local list, seen = {}, { [word:lower()] = true }
    if fix then seen[fix:lower()] = true end
    for _, c in ipairs(r.cands) do
        local l = c.word:lower()
        if not seen[l] then
            seen[l] = true
            list[#list + 1] = c
        end
    end
    -- letters that aren't a word yet are most likely the start of one, as on a phone: its likeliest goes first
    if not fix and not r.valid and list[1] then
        for i, c in ipairs(list) do
            if c.completion then
                if i > 1 and c.cost <= list[1].cost + COMPLETE_LEAD then table.insert(list, 1, table.remove(list, i)) end
                break
            end
        end
    end
    local cands = {}
    for i, c in ipairs(list) do cands[i] = c.word end
    return { word = word, cands = cands, fix = fix }
end

local function slotsFor(p)
    local s = {}
    if p.fix then
        s[1] = { label = "“" .. p.word .. "”", kind = "keep", word = p.word }
        s[2] = { label = p.fix, kind = "word", text = p.fix, word = p.word, bold = true }
        if p.cands[1] then s[3] = { label = p.cands[1], kind = "word", text = p.cands[1], word = p.word } end
    else
        -- the likeliest in the middle, the next two either side
        for i, pos in ipairs({ 2, 1, 3 }) do
            local w = p.cands[i]
            if w then s[pos] = { label = w, kind = "word", text = w, word = p.word } end
        end
    end
    return s
end

local function sameSlots(a, b)
    for i = 1, 3 do
        local x, y = a[i], b[i]
        if (x == nil) ~= (y == nil) then return false end
        if x and (x.label ~= y.label or x.kind ~= y.kind or x.word ~= y.word or x.bold ~= y.bold or x.gen ~= y.gen) then
            return false
        end
    end
    return true
end

-- Whether a word is one of the user's own (never corrected): put back after a correction or typed twice, in the
-- book open in Search & Ask, or in the names of the books on the Kindle.
function QuietKeyboard:isKnown(word)
    local w = word:lower()
    local stem = w:gsub("'s$", "") -- a name's possessive: Heathcliff's
    if keepSet()[w] or (Library and (Library[w] or Library[stem])) then return true end
    local ib = self.inputbox
    local book = ib and (ib.quiet_known_words or (ib.parent and ib.parent.quiet_known_words))
    return book and (book[w] or book[stem]) or false
end

-- The taps behind the word before the cursor, a character each: kept while it is the same word in the same place,
-- growing by the letter just typed (self.new_tap) or losing letters at its end. Anything else (a cursor move, even to
-- the same word elsewhere, a correction, a paste) and its characters have no places, as if tapped on their keys'
-- centres. at: where the word starts.
function QuietKeyboard:sync(word, at)
    local taps, new = (at and at == self.taps_at) and self.taps or {}, self.new_tap
    self.new_tap = nil
    local out, ok = {}, true
    for i, ch in ipairs(word and util.splitToChars(word) or {}) do
        local t = taps[i]
        if ok and t and t.ch == ch then
            out[i] = t
        elseif ok and not t and new and new.ch == ch then
            out[i], new = new, nil
        else
            ok = false
            out[i] = { ch = ch }
        end
    end
    self.taps, self.taps_at = out, at
end

-- The question for the decoder about the word before the cursor, without its closing apostrophes (see Suggest): "k"
-- when it's the user's own, the word with accents dropped, and where each letter was tapped ("-": not known).
function QuietKeyboard:tokenFor(word)
    local plain, places = {}, {}
    for i, ch in ipairs(util.splitToChars(word)) do
        local t = self.taps[i]
        local p = PLAIN[ch]
        if p then
            for c in p:gmatch(".") do plain[#plain + 1], places[#places + 1] = c, "-" end
        else
            plain[#plain + 1] = ch
            places[#places + 1] = (t and t.ch == ch and t.x) and string.format("%.0f,%.0f", t.x, t.y) or "-"
        end
    end
    local w = table.concat(plain)
    if #w == 0 or #w > 30 or not w:find("^[%a']+$") then return nil end
    return (self:isKnown(word) and "k" or "") .. "\t" .. w .. "\t" .. table.concat(places, ";")
end

-- The text changed: ask the decoder about the word now before the cursor, and redraw the row once typing pauses.
function QuietKeyboard:typed()
    if not self.bar then return end
    local word, _, at = self:currentWord()
    self.word, self.word_at = word, at
    self:sync(word, at)
    if self.undo and not self:undoHolds() then self.undo = nil end
    local stem = word and splitTail(word)
    self.asking = stem and stem ~= "" and self:tokenFor(stem) or nil
    if self.asking then Suggest.ask(self.asking, self.km) end
    if self.bar_fn then UIManager:unschedule(self.bar_fn) end
    self.bar_fn = safely(function()
        self.bar_fn = nil
        self:updateBar()
    end)
    UIManager:scheduleIn(BAR_DELAY_S, self.bar_fn)
end

-- The text or the cursor changed without a key (a tap in the text, a paste, a clear button, the whole text replaced):
-- the row follows, and the word's tap places go (whatever is before the cursor now, this keyboard didn't type it).
function QuietKeyboard:changed()
    if not self.editing then self.taps_at = nil end
    if self.change_fn then return end
    self.change_fn = safely(function()
        self.change_fn = nil
        if not self.visible then return end
        local word, _, at = self:currentWord()
        if word ~= self.word or at ~= self.word_at or (self.undo and not self:undoHolds()) then self:typed() end
    end)
    UIManager:nextTick(self.change_fn)
end

-- An answer came: the row waits for it only after typing has paused.
function QuietKeyboard:answered(token)
    if self.bar_waiting and token == self.asking and not self.bar_fn then self:updateBar() end
end

function QuietKeyboard:updateBar()
    if not self.visible or not self.bar then return end
    local word, _, at = self:currentWord()
    if word ~= self.word or at ~= self.word_at then return self:typed() end -- the text moved on since
    local slots = {}
    if self.undo then
        slots[1] = { label = "“" .. self.undo.original .. "”", kind = "revert", gen = self.undo.gen }
    elseif self.asking then
        local r = Suggest.answer(self.asking)
        if not r then
            self.bar_waiting = true -- drawn when the answer comes
            return
        end
        slots = slotsFor(self:plan((splitTail(self.word)), r))
    end
    self.bar_waiting = nil
    if sameSlots(slots, self.slots) then return end
    self.slots = slots
    for key, where in pairs(self.lit) do
        if where.bar then self.lit[key] = nil end
    end
    self:renderBar()
    local b = self.bar
    local rect = Geom:new{ x = b.x, y = b.y + 2, w = b.w, h = b.h - 2 } -- the line above stays as it is (grey)
    UIManager:setDirty(self, function() return "fast", rect end)
end

---------------------------------------------------------------------------------------------------- touches

-- Whether a window above this keyboard takes over: a modal or full-screen one (or one of unknown size) always,
-- any other only where it overlaps `rect`. Toasts don't count; they close on the next touch.
function QuietKeyboard:above(rect)
    local stack = UIManager._window_stack
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if w == self then return false end
        if not w.toast and not w.invisible then
            local d = w.dimen
            if w.modal or w.covers_fullscreen or not d or not d.x then return true end
            if rect and overlap(d, rect) then return true end
        end
    end
    return true -- not on the stack
end

-- Drop every finger and the timers they started (a window came over the keyboard, or routing failed).
function QuietKeyboard:cancelAll()
    self:disarmHold()
    for _, c in ipairs(self.contacts) do c.ignored = true end
    self.contacts = {}
    self:closePopup()
    if next(self.lit) then
        self.lit = {}
        if self.visible then UIManager:setDirty(self, function() return "ui", self.dimen end) end
    end
end

-- The key at the same place on the page showing now (a finger that landed before Shift or 123 took effect).
function QuietKeyboard:current(key, where)
    if where and (where.popup or where.bar) then return key end
    local keys = self:keys()
    for _, k in ipairs(keys) do
        if k == key then return key end
    end
    local cx, cy = key.x + key.w / 2, key.y + key.h / 2
    for _, k in ipairs(keys) do
        if inBox(cx, cy, k) then return k end
    end
    return nil
end

-- distance from a point to a key's box (0 inside)
local function dist2(lx, ly, k)
    local dx = math.max(k.x - lx, 0, lx - (k.x + k.w))
    local dy = math.max(k.y - ly, 0, ly - (k.y + k.h))
    return dx * dx + dy * dy
end

-- The key a touch at screen x, y means, and where that key is drawn. Between keys: the nearest one. On the
-- suggestion row: the word there, or nothing.
function QuietKeyboard:keyAt(x, y)
    local p = self.popup
    if p and inBox(x, y, p) then
        local best, bd
        for _, k in ipairs(p.keys) do
            local d = dist2(x - p.kx, y - p.ky, k)
            if not bd or d < bd then best, bd = k, d end
        end
        return best, self:popupWhere()
    end
    if self.bar and inBox(x, y, self.bar) then
        for _, k in pairs(self.bar_keys or {}) do
            if inBox(x - self.bar.x, y - self.bar.y, k) then return k, self:barWhere() end
        end
        return nil
    end
    if not inBox(x, y, self.rows) then return nil end
    local lx, ly = x - self.rows.x, y - self.rows.y
    local best, bd
    for _, k in ipairs(self:keys()) do
        local d = dist2(lx, ly, k)
        if d == 0 then return k end
        if not bd or d < bd then best, bd = k, d end
    end
    return best
end

function QuietKeyboard:held(key)
    for _, c in ipairs(self.contacts) do
        if c.key == key and not c.done then return true end
    end
    return false
end

function QuietKeyboard:down(c, x, y)
    local key, where = self:keyAt(x, y)
    -- a key another finger still holds: the same finger bouncing, not a new press (libkb drops it too)
    if not key or self:held(key) then
        c.ignored = true
        return
    end
    c.key, c.where, c.t0 = key, where, time.now()
    if not where then c.key0, c.x0, c.y0 = key, x - self.rows.x, y - self.rows.y end -- for the decoder
    self.contacts[#self.contacts + 1] = c
    self:light(key, true, where)
    self:armHold(c)
end

function QuietKeyboard:move(c, x, y)
    if c.ignored or c.done or not self.visible then return end
    if self:above() then return self:cancelAll() end
    local k = c.key
    local o = c.where or self:rowsWhere()
    local m = math.floor(Screen:getDPI() / 25.4 + 0.5) -- 1 mm: stays on its key until clearly past the edge
    if inBox(x - o.x, y - o.y, { x = k.x - m, y = k.y - m, w = k.w + 2 * m, h = k.h + 2 * m }) then return end
    local key, where = self:keyAt(x, y)
    if not key or key == k or self:held(key) then return end
    if self.lit[k] then self:light(k, false, self.lit[k]) end
    c.key, c.where, c.repeated = key, where, nil -- backspace's repeats don't carry over to the next key
    self:light(key, true, where)
    if not self.popup then self:armHold(c) end
end

function QuietKeyboard:up(c, x, y)
    self:disarmHold(c)
    if c.ignored or c.done or not self.visible then
        self:forget(c)
        if c.done then self:unlightSoon(c.key) end
        return
    end
    if self:above() then return self:cancelAll() end
    local key, key_where = c.key, c.where
    local at, at_where = self:keyAt(x, y)
    if at and at ~= key then
        local o = c.where or self:rowsWhere()
        local dx = math.abs(x - (o.x + key.x + key.w / 2))
        local dy = math.abs(y - (o.y + key.y + key.h / 2))
        local slipped = time.to_ms(time.since(c.t0)) < SLIP_MS and dx < key.w and dy < key.h / 2
        if not slipped then key, key_where = at, at_where end
    end
    -- every finger still down types now, in the order they landed (libkb: two fingers down, the first lift types
    -- both); their own lifts later type nothing
    local order = {}
    for _, d in ipairs(self.contacts) do
        if not d.done and not d.ignored then order[#order + 1] = d end
    end
    self:forget(c)
    local p = self.popup
    if p and key == p.base and not p.armed and #order == 1 then
        p.armed = true -- lifted on the key that opened the accents: they stay up for a tap
        self:unlightSoon(c.key)
        return
    end
    for _, d in ipairs(order) do
        d.done = true
        self:disarmHold(d)
        -- an earlier key may have changed the page (Shift, 123, a capital): type what is under the finger now
        local k = self:current(d == c and key or d.key, d == c and key_where or d.where)
        if k and not d.repeated then self:commit(k, self:placeOf(d, k)) end
        self:unlightSoon(d.key)
    end
end

-- Where the finger that typed key k landed, in keyboard coordinates, for the decoder: only when k is the key it landed
-- on (or the capital at that place). A finger that slid to its key, or a key on the accent row, has no place.
function QuietKeyboard:placeOf(c, k)
    local k0 = c.key0
    if k0 and (k0 == k or (k0.x == k.x and k0.y == k.y)) then return c.x0, c.y0 end
end

-- A finger whose lift never came (a new one took its slot, or the keyboard went away).
function QuietKeyboard:cancel(c)
    self:disarmHold(c)
    self:forget(c)
    if c.key and not c.ignored and self.lit[c.key] then self:light(c.key, false, self.lit[c.key]) end
end

function QuietKeyboard:forget(c)
    for i, d in ipairs(self.contacts) do
        if d == c then
            table.remove(self.contacts, i)
            return
        end
    end
end

function QuietKeyboard:unlightSoon(key)
    UIManager:scheduleIn(UNPRESS_S, safely(function()
        if self.visible and self.lit[key] and not self:held(key) then self:light(key, false, self.lit[key]) end
    end))
end

function QuietKeyboard:armHold(c)
    self:disarmHold()
    local key = c.key
    if not (key.hold and self.km.accents[key.hold]) and key.cmd ~= "back" then return end
    local n = 1
    local fire
    fire = safely(function()
        if self.hold_c ~= c or c.done or not self.visible then return end
        if self:above() then return self:cancelAll() end
        if key.cmd == "back" then
            self.undo = nil
            self:edit(function() self:delete(n > WORD_AFTER_N) end)
            self:typed()
            c.repeated = true
            n = n + 1
            local slow = n <= REPEAT_SLOW_N + 1 or n > WORD_AFTER_N + 1
            UIManager:scheduleIn(slow and HOLD_S or REPEAT_FAST_S, fire)
        else
            self.hold_c, self.hold_fn = nil, nil
            self:openPopup(key)
        end
    end)
    self.hold_c, self.hold_fn = c, fire
    UIManager:scheduleIn(HOLD_S, fire)
end

function QuietKeyboard:disarmHold(c)
    if self.hold_fn and (not c or self.hold_c == c) then
        UIManager:unschedule(self.hold_fn)
        self.hold_c, self.hold_fn = nil, nil
    end
end

---------------------------------------------------------------------------------------------------- typing

-- Runs fn (which edits the field) with the field's redraws sent as DU instead of KOReader's "ui": no flash, no
-- wait (see the top). That's every "ui" redraw inside the field: the field's own, and its text box's for the line
-- and the cursor (KOReader merges overlapping redraws into the strongest, so one "ui" left would make all of
-- them "ui" again). The REAGL redraw that smooths the letters follows once typing pauses.
function QuietKeyboard:edit(fn)
    local ib = self.inputbox
    local setDirty = UIManager.setDirty
    UIManager.setDirty = function(um, widget, refresh, ...)
        if widget == ib.parent and type(refresh) == "function" then
            local f = refresh
            refresh = function()
                local mode, region, dither = f()
                local d = ib.dimen
                if mode == "ui" and region and d and d.x and region.x and region.x >= d.x - 1 and region.y >= d.y - 1
                        and region.x + region.w <= d.x + d.w + 1 and region.y + region.h <= d.y + d.h + 1 then
                    mode = "fast"
                end
                return mode, region, dither
            end
        end
        return setDirty(um, widget, refresh, ...)
    end
    self.editing = true -- the field's own change hooks know it's this keyboard's (see changed())
    local ok, err = pcall(fn)
    self.editing = nil
    UIManager.setDirty = setDirty
    if not ok then error(err, 0) end
    if self.smooth_fn then UIManager:unschedule(self.smooth_fn) end
    self.smooth_fn = safely(function()
        self.smooth_fn = nil
        if self.visible and ib.dimen and ib.dimen.x then
            -- "[partial]": REAGL like "partial", but not counted towards KOReader's every-20th full (flashing) refresh
            UIManager:setDirty(ib.parent, function() return "[partial]", ib.dimen end)
        end
    end)
    UIManager:scheduleIn(SMOOTH_S, self.smooth_fn)
end

function QuietKeyboard:delete(word)
    local ib = self.inputbox
    if word then ib:delWord(true) else ib:delChar() end
end

-- The word being typed: the letters right before the cursor, when the cursor is at its end. Returns the word, its
-- length in characters and where it starts (its first character's index).
function QuietKeyboard:currentWord()
    local ib = self.inputbox
    local list, pos = ib and ib.charlist, ib and ib.charpos
    if type(list) ~= "table" or type(pos) ~= "number" or #list == 0 or wordChar(list[pos]) then return nil end
    local i = pos - 1
    while i >= 1 and wordChar(list[i]) do i = i - 1 end
    while i + 1 < pos and list[i + 1] == "'" do i = i + 1 end -- an opening quote mark isn't part of it
    if i + 1 >= pos then return nil end
    return table.concat(list, "", i + 1, pos - 1), pos - 1 - i, i + 1
end

-- Replaces the n characters before the cursor with text, in one redraw; the cursor ends `skip` characters on.
function QuietKeyboard:replace(n, text, skip)
    local ib = self.inputbox
    local pos = ib.charpos
    if ib.readonly or not ib:isTextEditable(true) or type(pos) ~= "number" or pos - 1 < n then return false end
    local chars = util.splitToChars(text)
    self:edit(function()
        for _ = 1, n do table.remove(ib.charlist, pos - n) end
        for i = #chars, 1, -1 do table.insert(ib.charlist, pos - n, chars[i]) end
        ib.charpos = math.min(pos - n + #chars + (skip or 0), #ib.charlist + 1)
        ib.undo_charlist = nil
        ib.is_text_edited = true
        ib:initTextBox(nil, true)
    end)
    return true
end

-- Corrects the word before the cursor when the decoder says to; returns what it replaced (for undo).
function QuietKeyboard:fix()
    if not self.bar then return nil end
    local word, len, at = self:currentWord()
    if not word then return nil end
    if word ~= self.word or at ~= self.word_at then self:typed() end -- text the keyboard hasn't seen yet
    local stem, tail = splitTail(word)
    if stem == "" then return nil end
    local r = self.asking and Suggest.wait(self.asking, self.km, FIX_WAIT_S)
    if not r then
        logWord("%s: no answer", stem)
        return nil
    end
    local p = self:plan(stem, r)
    -- an unknown word the decoder leaves as it is: the user's own once typed twice
    if not r.valid and not r.fix and not self:isKnown(stem) then learn(stem) end
    logWord("%s -> %s (%s, keep %.1f; %s)", stem, p.fix or "-", r.valid and "a word" or "unknown", r.cost or 0,
        table.concat(p.cands, " ", 1, math.min(#p.cands, 3)))
    if not p.fix or not self:replace(len, p.fix .. tail) then return nil end
    self.undo_gen = (self.undo_gen or 0) + 1
    return { original = word, fixed = p.fix .. tail, stem = stem, gen = self.undo_gen }
end

-- A word ends (space, punctuation, a new line): corrected first if it should be, and the correction can be taken back.
function QuietKeyboard:endWord(char)
    local ib = self.inputbox
    local fixed = self:fix()
    self:edit(function() ib:addChars(char) end)
    if fixed then
        fixed.after, fixed.pos = char, ib.charpos
        self.undo = fixed
    end
end

-- Whether the text right before the cursor is still the last correction and what followed it (and how many
-- characters that is).
function QuietKeyboard:undoHolds()
    local u, ib = self.undo, self.inputbox
    if not u or not ib or type(ib.charpos) ~= "number" then return false end
    local tail = u.fixed .. u.after
    local n = nchars(tail)
    return ib.charpos == u.pos and ib.charpos - 1 >= n
        and table.concat(ib.charlist, "", ib.charpos - n, ib.charpos - 1) == tail, n
end

-- Puts back what was typed before the last correction, while the cursor is still right after it. keep_after:
-- the space (or mark) that followed stays (a tap on the row), or goes too (backspace).
function QuietKeyboard:revert(keep_after)
    local u = self.undo
    local holds, n = self:undoHolds()
    self.undo = nil
    if not holds or not self:replace(n, u.original .. (keep_after and u.after or "")) then return false end
    keep(u.stem or u.original)
    logWord("%s: put back (was %s)", u.original, u.fixed)
    return true
end

-- A word on the suggestion row was tapped.
function QuietKeyboard:accept(e)
    if e.kind == "revert" then
        -- only the correction the row was drawn for (a later one may have come before the row caught up)
        if not self.undo or self.undo.gen ~= e.gen then return end
        return self:revert(true)
    end
    self.undo = nil
    local ib = self.inputbox
    local word, len = self:currentWord()
    if not word then return end
    local stem, tail = splitTail(word)
    if stem ~= e.word then return end -- the text has moved on since the row was drawn
    local space_follows = ib.charlist[ib.charpos] == " "
    if e.kind == "keep" then
        keep(stem)
        if space_follows then self:replace(0, "", 1) else self:edit(function() ib:addChars(" ") end) end
    else
        local text = e.text .. tail
        self:replace(len, space_follows and text or text .. " ", space_follows and 1 or 0)
    end
end

-- x, y: where a letter was tapped (keyboard coordinates), when known.
function QuietKeyboard:commit(key, x, y)
    local ib = self.inputbox
    if not ib then return end
    local cmd = key.cmd
    self:closePopup() -- any key typed puts the accents away, as libkb does
    if cmd == "shift" then
        return self:setPage(self.page == "lower" and "shift" or "lock")
    elseif cmd == "lower" or cmd == "abc" then
        return self:setPage("lower")
    elseif cmd == "123" or cmd == "prev" then
        return self:setPage("num1")
    elseif cmd == "next" then
        return self:setPage("num2")
    end
    -- the text changes from here on
    if cmd == "suggest" then
        self:accept(key.entry)
    elseif cmd == "back" then
        if not self:revert(false) then -- right after a correction, backspace takes it back
            self:edit(function() self:delete(false) end)
        end
    else
        self.undo = nil
        if cmd == "return" then
            if ib.enter_callback then
                self:fix()
                UIManager:nextTick(function() ib.enter_callback() end)
            else
                self:endWord("\n") -- a new line, corrected as a space would be (and backspace takes that back)
            end
        elseif cmd == "space" then
            self:endWord(" ")
        elseif key.text then
            if ENDS[key.text] then
                self:endWord(key.text)
            else
                if wordChar(key.text) then self.new_tap = { ch = key.text, x = x, y = y } end
                self:edit(function() ib:addChars(key.text) end)
            end
            if self.page == "shift" then self:setPage("lower") end
        end
    end
    self:typed()
end

function QuietKeyboard:onShow()
    self.visible = true
    shown[self] = true
    if self.bar then
        if Suggest.start() then Suggest.keys(self.km) end -- ready before the first word
        self.slots, self.undo, self.word, self.asking, self.taps = {}, nil, nil, nil, {}
        self:renderBar()
        self:typed() -- the word the cursor may already be at the end of
        if not Library then UIManager:scheduleIn(1, safely(libraryWords)) end
    end
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function QuietKeyboard:onCloseWidget()
    self:disarmHold()
    for _, c in ipairs(self.contacts) do c.ignored = true end
    self.contacts = {}
    if self.popup then
        local rect = self:popupRect()
        self.popup.bb:free()
        self.popup = nil
        UIManager:setDirty(nil, function() return "ui", rect end)
    end
    for _, name in ipairs({ "bar_fn", "change_fn" }) do
        if self[name] then
            UIManager:unschedule(self[name])
            self[name] = nil
        end
    end
    self.lit = {}
    self.visible = false
    shown[self] = nil
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function QuietKeyboard:free()
    if self.bar_bb then
        self.bar_bb:free()
        self.bar_bb = nil
    end
    VirtualKeyboard.free(self)
end

---------------------------------------------------------------------------------------------------- the touch hook

-- The keyboard on top at screen x, y, if any: windows above it that cover the point take the touch instead.
local function keyboardAt(x, y)
    local stack = UIManager._window_stack
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if shown[w] then
            if inBox(x, y, w.dimen) or (w.popup and inBox(x, y, w.popup)) then return w end
        elseif not w.toast and not w.invisible then
            local d = w.dimen
            if w.modal or w.covers_fullscreen or not d or not d.x or inBox(x, y, d) then return nil end
        end
    end
    return nil
end

local owned = {}   -- slot -> contact, for fingers that landed on the keyboard
local last_id = {} -- slot -> the tracking id last seen there

local function toScreen(gd, x, y)
    if Screen:getTouchRotation() == 0 then return x, y end
    local ges = { ges = "tap", pos = Geom:new{ x = x, y = y, w = 0, h = 0 } }
    gd:adjustGesCoordinate(ges)
    return ges.pos.x, ges.pos.y
end

local function route(gd, tevs)
    local pass, touched = {}, false
    for _, tev in ipairs(tevs) do
        local s, id = tev.slot, tev.id
        local c = owned[s]
        if c and id ~= -1 and id ~= c.id then -- a new finger in that slot: the old one's lift never came
            owned[s] = nil
            if not c.dead then c.kb:cancel(c) end
            c = nil
        end
        local fresh = id ~= nil and id ~= -1 and id ~= last_id[s]
        last_id[s] = id
        if c and c.dead then -- left over from a failed routing: swallowed until it lifts
            if id == -1 then owned[s] = nil end
        elseif c then
            local x, y = toScreen(gd, tev.x, tev.y)
            if id == -1 then
                owned[s] = nil
                touched = true
                c.kb:up(c, x, y)
            else
                c.kb:move(c, x, y)
            end
        elseif fresh and next(shown) and tev.x and tev.y then
            local x, y = toScreen(gd, tev.x, tev.y)
            local kb = keyboardAt(x, y)
            if kb then
                c = { slot = s, id = id, kb = kb }
                owned[s] = c
                touched = true
                kb:down(c, x, y)
            else
                pass[#pass + 1] = tev
            end
        else
            pass[#pass + 1] = tev
        end
    end
    -- the gesture detector never sees these touches, so KOReader's once-per-input hook (AutoSuspend's idle timer,
    -- the light's touch samples) is told here
    if touched then UIManager.event_hook:execute("InputEvent") end
    return pass
end

-- Routing failed part-way: every finger on a keyboard is let go (no key repeats on after it), and the rest of those
-- touches is swallowed, so the gesture detector never gets half a touch.
local function abandon(tevs)
    for s, c in pairs(owned) do
        if not c.dead then
            pcall(c.kb.cancelAll, c.kb)
            owned[s] = { id = c.id, dead = true }
        end
    end
    for kb in pairs(shown) do pcall(kb.cancelAll, kb) end
    local pass = {}
    for _, tev in ipairs(tevs) do
        local c = owned[tev.slot]
        if not c then
            pass[#pass + 1] = tev
        elseif tev.id == -1 then
            owned[tev.slot] = nil
        end
    end
    return pass
end

local gd = Device.input and Device.input.gesture_detector
if gd and Device:isTouchDevice() and not gd.quiet_keyboard_feed then
    local feed = gd.feedEvent
    gd.quiet_keyboard_feed = feed
    gd.feedEvent = function(self, tevs)
        if not next(shown) and not next(owned) then
            for _, tev in ipairs(tevs) do last_id[tev.slot] = tev.id end
            return feed(self, tevs)
        end
        local ok, pass = pcall(route, self, tevs)
        if not ok then
            logger.warn("quiet keyboard: touch routing failed:", pass)
            pass = abandon(tevs)
        end
        return feed(self, pass)
    end
end

-- The keyboard language KOReader would use (its own resolution: remembered layout, default, interface language;
-- anything it has no layout for gets English, as in VirtualKeyboard:init).
local function english()
    local ok, lang = pcall(VirtualKeyboard.getKeyboardLayout, VirtualKeyboard)
    if not ok then return false end
    local layouts = VirtualKeyboard.lang_to_keyboard_layout or {}
    return (layouts[lang] or "en_keyboard") == "en_keyboard"
end

-- Text and cursor changes made without the keyboard (initTextBox: any change of text; resyncPos: the cursor moved).
local function changed(ib, ...)
    local kb = ib.keyboard
    if kb and shown[kb] and kb.bar then kb:changed() end
    return ...
end
for _, name in ipairs({ "initTextBox", "resyncPos" }) do
    local orig = InputText[name]
    if type(orig) == "function" then
        InputText[name] = function(self, ...) return changed(self, orig(self, ...)) end
    end
end

local initKeyboard = InputText.initKeyboard
function InputText:initKeyboard()
    if gd and gd.quiet_keyboard_feed and G_reader_settings:isTrue("quiet_keyboard") and english()
            and QuietKeyboard.available() then
        self.key_events = {}
        self.keyboard = QuietKeyboard:new{ inputbox = self }
        return
    end
    return initKeyboard(self)
end

-- The letters page drawn while nothing else happens, so the first keyboard comes up at once; then the words helper
-- started, so its words are in before the first one is typed.
UIManager:scheduleIn(5, function()
    if not G_reader_settings:isTrue("quiet_keyboard") then return end
    local km = keymap(Screen:getWidth(), Screen:getHeight())
    if km then pcall(pageBB, km, "lower", Screen:getWidth()) end
end)
UIManager:scheduleIn(8, safely(function()
    if not (G_reader_settings:isTrue("quiet_keyboard") and G_reader_settings:isTrue("quiet_keyboard_suggest")) then
        return
    end
    local km = keymap(Screen:getWidth(), Screen:getHeight())
    if km and english() and Suggest.start() then Suggest.keys(km) end
end))

return QuietKeyboard
