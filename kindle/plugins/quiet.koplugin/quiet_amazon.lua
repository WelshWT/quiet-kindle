--[[
Amazon's side of the Kindle, one tap away and back again:
  - Amazon.open(book): one of your Kindle Store books (DRM'd KFX/PDOC that only Amazon's reader can open)
    opens straight in Amazon's reader; closing it (Home or Back there) brings KOReader back.
  - Amazon.openStore(): the Kindle Store itself, as Amazon's cart button opens it; closing the Store (its ✕, Home
    or Back) brings KOReader back, so shopping is a round trip.
  - Amazon.openHome(): Amazon's home, and KOReader stays closed: you chose to be in Amazon's OS. You come back
    with KOReader in Amazon's library.

How, on firmware 5.19.6 (through the Kindle's own app manager, appmgrd, as seen working on this Kindle):
  - Amazon's reader is the booklet com.lab126.booklet.reader. Started with
    app://com.lab126.booklet.reader<percent-encoded path of the book file> it opens that file. It is a URI,
    so the path must be percent-encoded (spaces, commas).
  - The Store is the KPP app com.lab126.KPPStoreShopping (appreg.db); Amazon's cart button starts
    app://com.lab126.KPPStoreShopping?action=storefront&handling=system&ingress=CartIconOnChromeBar&requestTimestamp=…
    (appmgrd's activeContext right after a tap on it), and so do we.
  - None of it can open over KOReader: KOReader's launcher stops the reader's services (kfxreader, kfxview, …) and
    freezes the window manager while KOReader runs, and only puts them back when KOReader exits (then starts
    Amazon's home). So the URI goes to quiet_amazon_open.sh, started detached, KOReader exits the normal way
    (the Exit event), and the script opens the book or the Store once the launcher has put Amazon's UI back.
  - The way back is that script too: it waits, without polling, for Amazon's home or library to come up afterwards
    and then starts KOReader the way tapping KOReader in Amazon's library does. It ends without doing anything
    when KOReader is started some other way, after 12 hours, or when another one is started.

    local Amazon = require("quiet_amazon")
    Amazon.supported()  -- true when this Kindle has what the direct open needs (Store too)
    Amazon.open{ asin = "B0…", path = "<cc.db p_location>", cde_type = "EBOK", title = "…" }
    Amazon.openStore()
    Amazon.openHome()
]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Amazon = {}

-- Seen working on this Kindle (fw 5.19.6, 2026-10-19): Dark Matter (PDOC) and DCC 8 (DRM'd EBOK) opened at
-- their last page in ~14 s, Home in Amazon's reader brought KOReader back in ~6 s. Amazon's own home opens a
-- book with the same percent-encoded path (its activeContext: file:///mnt/us/documents/Downloads/…%20…%2C…).
local VERIFIED = true
-- The Store round trip. Opening is seen working (2026-10-19 20:22 and 20:30: the storefront, ~12 s), but closing
-- it with its ✕ wasn't: the first try started the Store while Amazon's home was still starting (now waited out
-- in the script), and from then on Amazon's UI took no injected touches at all, so the ✕ couldn't be tested.
-- Until a clean run shows ✕ → KOReader, openStore() goes to Amazon's home and points at the cart.
local STORE_VERIFIED = false

local READER_URI, READER_APP = "app://com.lab126.booklet.reader", "com.lab126.booklet.reader"
local STORE_URI = "app://com.lab126.KPPStoreShopping?action=storefront&handling=system&ingress=CartIconOnChromeBar"
local STORE_APP = "com.lab126.KPPStoreShopping"
-- Each handoff is a request: its id goes to REQ_FILE (written here, and only here) and, with everything else the
-- helper needs, onto its command line. The helper acts only while its id is the latest and the KOReader session
-- that asked (READY: the time the bridge saw KOReader start) is still the last one; so a newer request, or calling
-- a waiting helper off, is just a new id in REQ_FILE. No pid files, no kills (review C6 rounds 2-4).
local REQ_FILE, READY = "/tmp/quiet-amazon.req", "/tmp/quiet-ready"
local request_seq = 0
local HELPER = "quiet_amazon_open.sh"
local NEEDS = { "/usr/bin/lipc-set-prop", "/usr/bin/lipc-get-prop", "/usr/bin/lipc-wait-event",
    "/opt/amazon/ebook/booklet/Reader.jar" }

local function exists(path)
    return path and lfs.attributes(path, "mode") ~= nil
end

local function helperPath()
    local src = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
    return src .. HELPER
end

-- Everything but unreserved characters and "/" as %XX, so the reader gets the path back exactly.
function Amazon.encodePath(path)
    return (path:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

function Amazon.uri(path)
    return READER_URI .. Amazon.encodePath(path)
end

function Amazon.supported()
    if not VERIFIED then return false end
    return Amazon.ready()
end

-- What the direct open needs, regardless of VERIFIED (for testing it before switching it on).
function Amazon.ready()
    for _, p in ipairs(NEEDS) do
        if not exists(p) then return false end
    end
    return exists(helperPath())
end

local function shellQuote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function writeFile(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local text = f:read("*a") or ""
    f:close()
    return text
end

local function say(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
end

-- Leave KOReader the normal way: books are saved, settings flushed, and the launcher restores Amazon's UI.
-- KOReader only quits once no window is left, and the Exit event closes just the file manager (or the book):
-- a window that doesn't handle it, such as search results or a sheet, would keep KOReader running and the book
-- would never open. So whatever is still up a tick later is closed too. The short delay lets a message paint.
function Amazon.leaveKOReader(delay)
    UIManager:scheduleIn(delay or 0.3, function()
        UIManager:broadcastEvent(Event:new("Exit"))
        UIManager:nextTick(function()
            local left = {}
            for _, window in ipairs(UIManager._window_stack) do left[#left + 1] = window.widget end
            for i = #left, 1, -1 do UIManager:close(left[i]) end
        end)
    end)
end
local exitKOReader = Amazon.leaveKOReader

-- A new request id: unique within this KOReader session (two taps in the same second differ), and across sessions
-- (each starts at a different second).
local function newRequestId()
    request_seq = request_seq + 1
    return string.format("%d.%d", os.time(), request_seq)
end

-- Call off a script still waiting to bring KOReader back (there shouldn't be one while KOReader runs: it stops
-- once KOReader is back; this makes "stay in Amazon's OS" certain). A new id is enough: it acts only on its own.
function Amazon.cancelReturn()
    writeFile(REQ_FILE, "cancelled." .. newRequestId())
end

-- Hand `uri` to the script, which starts it once KOReader is gone and waits for `app` to come up.
local function launch(uri, app, message, opts)
    local id = newRequestId()
    if not writeFile(REQ_FILE, id) then return false end
    local mark = readFile(READY):gsub("%s+$", "")
    local args = { id, mark, app, uri, opts.stay and "stay" or "return" }
    for i, a in ipairs(args) do args[i] = shellQuote(a) end
    -- setsid: the script outlives KOReader and its launcher's clean-up
    os.execute("setsid sh " .. shellQuote(helperPath()) .. " " .. table.concat(args, " ")
        .. " </dev/null >/dev/null 2>&1 &")
    say(message)
    exitKOReader()
    return true
end

-- Opens `book` in Amazon's reader. Without a usable path (or on a Kindle that can't) it falls back to what the
-- Store row always did: leave KOReader for Amazon's home. opts.stay = true skips the trip back to KOReader.
function Amazon.open(book, opts)
    opts = opts or {}
    local path = book and book.path
    if (Amazon.supported() or opts.force) and Amazon.ready() and path and exists(path) then
        local title = book.title and book.title ~= "" and book.title or "your book"
        if launch(Amazon.uri(path), READER_APP, "Opening " .. title .. " in Kindle's reader\u{2026}", opts) then
            return true
        end
    end
    logger.warn("quiet amazon: can't open directly, leaving for Amazon's home:", path)
    exitKOReader()
    return false
end

-- Opens the Kindle Store; closing it brings KOReader back. Where that can't be done: Amazon's home, and it says so.
function Amazon.openStore(opts)
    opts = opts or {}
    if ((Amazon.supported() and STORE_VERIFIED) or opts.force) and Amazon.ready() then
        -- requestTimestamp in ms, as the cart button sends it
        local uri = STORE_URI .. "&requestTimestamp=" .. os.time() .. "000"
        if launch(uri, STORE_APP, "Opening the Kindle Store\u{2026}", opts) then return true end
    end
    logger.warn("quiet amazon: Store not available directly, leaving for Amazon's home")
    say("Going to Kindle home \u{2014} the Store is the cart at its top right.")
    exitKOReader()
    return false
end

-- Leaves KOReader for Amazon's home, and KOReader stays closed until you open it from Amazon's library.
function Amazon.openHome()
    Amazon.cancelReturn()
    say("Going to Kindle home\u{2026}")
    exitKOReader()
    return true
end

return Amazon
