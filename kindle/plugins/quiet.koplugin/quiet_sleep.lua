--[[
Sleep screens (asked 20 Oct: "better options for sleeping screen ... make sure the performance and consistency
are really solid"). What the Kindle shows while it sleeps; patches/2-quiet-sleep.lua hands the image to KOReader's
screensaver, whose show, rotation and wake-up stay KOReader's own.
  - quiet-1 .. quiet-5: the QUIET covers in data/quiet-sleep/, light or dark (made by tools/sleep-covers); quiet-3,
    the 3D block, to start with. Decoded once and kept, so a sleep only copies it.
  - Shuffle (asked for: "only when u have one of the text ones selected and shuffle between those"): a switch on the
    QUIET covers, not a screen of its own; on, each sleep shows one of the five, never the same one twice running.
  - cover: the book you're reading, rounded like every cover, with the progress line Home and the Library show.
    Its scaled cover is kept in memory and on disk, so only the first sleep ever with a book does the slow part.
  - frosted: the screen as it was, behind frosted glass: shrunk 4x with MuPDF, a box blur (three passes, close to a
    Gaussian) on that small copy, grown back and lifted 36% toward white. Nothing drawn over it.
Anything that fails falls back to the default cover, so the Kindle never sleeps on a broken screen.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local ffi = require("ffi")
local logger = require("logger")
local time = require("ui/time")
local Screen = Device.screen

local M = {}

M.MODES = {
    { id = "quiet-1", name = "Block" },
    { id = "quiet-2", name = "Big Q" },
    { id = "quiet-3", name = "3D block" },
    { id = "quiet-4", name = "3D Q" },
    { id = "quiet-5", name = "Diagonal" },
    { id = "cover", name = "Book cover" },
    { id = "frosted", name = "Frosted" },
}
M.DEFAULT = "quiet-3"
M.COVERS = { "quiet-1", "quiet-2", "quiet-3", "quiet-4", "quiet-5" }

function M.mode()
    local m = G_reader_settings:readSetting("quiet_sleep")
    for _, it in ipairs(M.MODES) do
        if it.id == m then return m end
    end
    return M.DEFAULT
end

function M.isQuiet(id) return type(id) == "string" and id:match("^quiet%-%d$") ~= nil end

function M.setMode(id) G_reader_settings:saveSetting("quiet_sleep", id) end
function M.shuffle() return G_reader_settings:isTrue("quiet_sleep_shuffle") end
function M.setShuffle(on) G_reader_settings:saveSetting("quiet_sleep_shuffle", on and true or false) end
function M.dark() return G_reader_settings:isTrue("quiet_sleep_dark") end
function M.setDark(on) G_reader_settings:saveSetting("quiet_sleep_dark", on and true or false) end

function M.name(id)
    for _, it in ipairs(M.MODES) do
        if it.id == id then return it.name end
    end
end

-- What the Sleep screen row says: "3D block", "Shuffle · Dark", "Book cover", "Frosted".
function M.summary()
    local mode = M.mode()
    if not M.isQuiet(mode) then return M.name(mode) end
    return (M.shuffle() and "Shuffle" or M.name(mode)) .. (M.dark() and " \u{00B7} Dark" or "")
end

function M.dataDir()
    local DataStorage = require("datastorage")
    local dir = DataStorage.getFullDataDir and DataStorage:getFullDataDir() or DataStorage:getDataDir()
    return dir .. "/data/quiet-sleep/"
end

-- The panel's own orientation (portrait on the Paperwhite): what a sleep screen is drawn in.
local function panelSize()
    local w, h = Screen:getWidth(), Screen:getHeight()
    return math.min(w, h), math.max(w, h)
end

-- Any blitbuffer as 8-bit grey (what the panel shows); frees the original when it converts.
local function grey(bb)
    if bb:getType() == Blitbuffer.TYPE_BB8 then return bb end
    local g = Blitbuffer.new(bb:getWidth(), bb:getHeight(), Blitbuffer.TYPE_BB8)
    g:blitFrom(bb, 0, 0, 0, 0, bb:getWidth(), bb:getHeight())
    bb:free()
    return g
end

-- QUIET covers ---------------------------------------------------------------------------------------------------

local cached = { path = nil, bb = nil } -- the last cover decoded (2 MB): a sleep copies it

local function coverFile(id, dark)
    return M.dataDir() .. id .. (dark and "-dark" or "") .. ".png"
end

function M.quietCover(id, dark)
    local path = coverFile(id, dark)
    if cached.path ~= path then
        local RenderImage = require("ui/renderimage")
        local bb = RenderImage:renderImageFile(path, false)
        if not bb then
            logger.warn("quiet sleep: cover not readable:", path)
            return nil
        end
        if cached.bb then cached.bb:free() end
        cached.path, cached.bb = path, grey(bb)
    end
    return cached.bb:copy()
end

local last_shuffled
function M.shuffleNext()
    local pool = {}
    for _, id in ipairs(M.COVERS) do
        if id ~= last_shuffled then pool[#pool + 1] = id end
    end
    last_shuffled = pool[math.random(#pool)]
    return last_shuffled
end

-- Frosted --------------------------------------------------------------------------------------------------------

-- Box blur of an 8-bit grey buffer in place (w x h pixels, `stride` bytes a row), `passes` times each way, with a
-- running sum so the cost doesn't grow with the radius. Edges repeat the border pixel. Pure FFI, testable alone.
function M.boxBlur(data, w, h, stride, r, passes)
    local win = 2 * r + 1
    local tmp = ffi.new("uint8_t[?]", math.max(w, h))
    for _ = 1, passes do
        for y = 0, h - 1 do
            local row = data + y * stride
            local sum = 0
            for i = -r, r do sum = sum + row[math.min(w - 1, math.max(0, i))] end
            for x = 0, w - 1 do
                tmp[x] = math.floor((sum + r) / win)
                sum = sum + row[math.min(w - 1, x + r + 1)] - row[math.max(0, x - r)]
            end
            ffi.copy(row, tmp, w)
        end
        for x = 0, w - 1 do
            local sum = 0
            for i = -r, r do sum = sum + data[math.min(h - 1, math.max(0, i)) * stride + x] end
            for y = 0, h - 1 do
                tmp[y] = math.floor((sum + r) / win)
                sum = sum + data[math.min(h - 1, y + r + 1) * stride + x] - data[math.max(0, y - r) * stride + x]
            end
            for y = 0, h - 1 do data[y * stride + x] = tmp[y] end
        end
    end
end

M.FROST_SHRINK, M.FROST_RADIUS, M.FROST_PASSES, M.FROST_VEIL = 4, 5, 3, 0.36

function M.frosted()
    local Mupdf = require("ffi/mupdf")
    local src = Screen.bb:copy()
    -- read exactly what the panel shows: the memory as it is (software night mode marks the buffer "inverse"; the
    -- memory itself is what's shown), flipped when night mode is the panel's own inversion (the memory is the day
    -- view). KOReader's image widget keeps an image's own colours in night mode, so this shows as it was seen.
    src:setInverse(0)
    -- and in the panel's own orientation: the sleep screen is shown upright, whatever the reading rotation
    src:setRotation(0)
    if Screen.night_mode and Device:canHWInvert() then src:invertRect(0, 0, src:getWidth(), src:getHeight()) end
    local w, h = src:getWidth(), src:getHeight()
    local sw, sh = math.floor(w / M.FROST_SHRINK), math.floor(h / M.FROST_SHRINK)
    local small = grey(Mupdf.scaleBlitBuffer(src, sw, sh))
    src:free()
    M.boxBlur(ffi.cast("uint8_t *", small.data), sw, sh, small.stride, M.FROST_RADIUS, M.FROST_PASSES)
    -- the screensaver turns a sideways screen upright before it draws, but leaves upside down as it is: there the
    -- image is drawn turned with the screen, so it is turned back first (MuPDF reads the memory, not the turn)
    if Screen:getRotationMode() == Screen.DEVICE_ROTATED_UPSIDE_DOWN then
        local turned = small:rotatedCopy(180)
        small:free()
        small = turned
    end
    local big = grey(Mupdf.scaleBlitBuffer(small, w, h))
    small:free()
    -- the frost: toward white, or toward black in night mode so a dark screen stays dark
    if Screen.night_mode then big:darkenRect(0, 0, w, h, M.FROST_VEIL) else big:lightenRect(0, 0, w, h, M.FROST_VEIL) end
    return big
end

-- Book cover -----------------------------------------------------------------------------------------------------

-- The book's cover at sleep size. Reading it out of the book is the slow part (measured from Home: ~0.4 s, 0.9 s just
-- after KOReader starts, mostly opening the book), so it is kept in memory and, as raw grey bytes, on disk for the
-- last few books (cache/quiet-sleep/, ~1 MB each, read back in ~15 ms): only the first sleep ever with a book pays.
-- The key holds the book file's size and time and any custom cover, so a new cover or a changed book is read again.
local scaled = { key = nil, bb = nil }
M.ART_KEEP = 6

local function artKey(file, box_w, box_h)
    local lfs = require("libs/libkoreader-lfs")
    local a = lfs.attributes(file)
    if not a then return nil end
    local key = table.concat({ file, a.size, a.modification, box_w, box_h }, "|")
    local ok, DocSettings = pcall(require, "docsettings")
    local custom = ok and DocSettings:findCustomCoverFile(file)
    if custom then key = key .. "|" .. custom .. "|" .. tostring(lfs.attributes(custom, "modification")) end
    return key
end

local function artDir() return require("datastorage"):getDataDir() .. "/cache/quiet-sleep/" end
local function artPath(file) return artDir() .. require("ffi/sha2").md5(file) .. ".bb8" end

-- File: "QSC1 <w> <h> <key>\n", then w x h grey bytes, row after row.
local function readArt(file, key)
    local path = artPath(file)
    local f = io.open(path, "rb")
    if not f then return nil end
    local w, h, k = (f:read("*l") or ""):match("^QSC1 (%d+) (%d+) (.*)$")
    w, h = tonumber(w), tonumber(h)
    local data = w and k == key and f:read(w * h)
    f:close()
    if not data or #data ~= w * h then return nil end
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local dst, src = ffi.cast("uint8_t *", bb.data), ffi.cast("const uint8_t *", data)
    for y = 0, h - 1 do ffi.copy(dst + y * bb.stride, src + y * w, w) end
    pcall(require("libs/libkoreader-lfs").touch, path) -- recently used: kept when older books are dropped
    return bb
end

local function writeArt(file, key, bb)
    local lfs = require("libs/libkoreader-lfs")
    local dir = artDir()
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    local w, h = bb:getWidth(), bb:getHeight()
    local path = artPath(file)
    local f = io.open(path .. ".part", "wb")
    if not f then return end
    f:write(string.format("QSC1 %d %d %s\n", w, h, key))
    local p = ffi.cast("uint8_t *", bb.data)
    for y = 0, h - 1 do f:write(ffi.string(p + y * bb.stride, w)) end
    f:close()
    os.rename(path .. ".part", path)
    local files = {}
    for name in lfs.dir(dir) do
        if name:match("%.bb8$") then
            files[#files + 1] = { name = name, t = lfs.attributes(dir .. name, "modification") or 0 }
        end
    end
    table.sort(files, function(a, b) return a.t > b.t end)
    for i = M.ART_KEEP + 1, #files do os.remove(dir .. files[i].name) end
end

local function maskCorners(bb, x, y, w, h, r, color)
    r = math.min(r, math.floor(h / 2), math.floor(w / 2))
    for dy = 0, r - 1 do
        local yy = r - dy - 0.5
        local inset = math.floor(r - math.sqrt(r * r - yy * yy) + 0.5)
        if inset > 0 then
            bb:paintRect(x, y + dy, inset, 1, color)
            bb:paintRect(x + w - inset, y + dy, inset, 1, color)
            bb:paintRect(x, y + h - 1 - dy, inset, 1, color)
            bb:paintRect(x + w - inset, y + h - 1 - dy, inset, 1, color)
        end
    end
end

-- "2% · 5 h 34 min left", "Finished", or nil: the same words the Library and Home use.
local function progressLine(ui, file)
    local pct, finished
    if ui and ui.document then
        local footer = ui.view and ui.view.footer
        pct = footer and footer.percent_finished
        finished = ui.doc_settings and (ui.doc_settings:readSetting("summary") or {}).status == "complete"
    else
        local ok, BookList = pcall(require, "ui/widget/booklist")
        local info = ok and BookList.getBookInfo(file) or {}
        pct, finished = info.percent_finished, info.status == "complete"
    end
    if finished then return "Finished", 1 end
    if not pct then return nil end
    local ok, RT = pcall(require, "quiet_readtime")
    local words = ok and type(RT) == "table" and RT.percentText and RT.percentText(pct)
        or string.format("%d%%", math.max(1, math.floor(pct * 100 + 0.5)))
    if ok and type(RT) == "table" then
        local okl, t = pcall(function() return ui and ui.document and RT.forUI(ui) or RT.forFile(file) end)
        if okl and type(t) == "table" and t.left_secs and t.left_secs > 0 then
            words = words .. " \u{00B7} " .. RT.format(math.max(60, t.left_secs)) .. " left"
        end
    end
    return words, pct
end

function M.bookCover(ui)
    local lfs = require("libs/libkoreader-lfs")
    local file = ui and ui.document and ui.document.file or G_reader_settings:readSetting("lastfile")
    if not file or lfs.attributes(file, "mode") ~= "file" or not (ui and ui.bookinfo) then return nil end
    local Q = require("quiet_ui")
    local W, H = panelSize()
    local top, bottom = Q.px(130), Q.px(300)
    local box_w, box_h = W - 2 * Q.px(130), H - top - bottom
    local key = artKey(file, box_w, box_h)
    if not key then return nil end
    if scaled.key ~= key then
        local okr, art = pcall(readArt, file, key)
        local fresh = not (okr and art)
        if fresh then
            local raw = ui.bookinfo:getCoverImage(ui.document, file)
            if not raw then return nil end
            local s = math.min(box_w / raw:getWidth(), box_h / raw:getHeight())
            local RenderImage = require("ui/renderimage")
            art = grey(RenderImage:scaleBlitBuffer(raw, raw:getWidth() * s, raw:getHeight() * s, true))
        end
        if scaled.bb then scaled.bb:free() end
        scaled.key, scaled.bb = key, art
        if fresh then
            -- onto disk a second later, once the sleep screen is up (the write takes ~50 ms)
            require("ui/uimanager"):scheduleIn(1, function()
                if scaled.key ~= key or not scaled.bb then return end
                local okw, err = pcall(writeArt, file, key, scaled.bb)
                if not okw then logger.warn("quiet sleep: cover not kept:", err) end
            end)
        end
    end
    local art = scaled.bb
    local aw, ah = art:getWidth(), art:getHeight()
    local canvas = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
    canvas:fill(Blitbuffer.COLOR_WHITE)
    local x, y = math.floor((W - aw) / 2), top + math.floor((box_h - ah) / 2)
    local r, edge = Q.px(26), Q.px(3)
    -- Quiet's cover: a thin soft edge, the image inside it, its corners following the curve
    Q.fillRound(canvas, x - edge, y - edge, aw + 2 * edge, ah + 2 * edge, Blitbuffer.gray(0.30),
        r + edge, r + edge, r + edge, r + edge)
    canvas:blitFrom(art, x, y, 0, 0, aw, ah)
    maskCorners(canvas, x, y, aw, ah, r, Blitbuffer.gray(0.30))
    local words, pct = progressLine(ui, file)
    if words then
        local ty, th = y + ah + Q.px(60), Q.px(6)
        local tr = math.floor(th / 2)
        Q.fillRound(canvas, x, ty, aw, th, Q.TRACK, tr, tr, tr, tr)
        Q.fillRound(canvas, x, ty, math.max(th, math.floor(aw * math.min(1, pct or 0))), th, Q.INK, tr, tr, tr, tr)
        local TextWidget = require("ui/widget/textwidget")
        local t = TextWidget:new{ text = words, face = Q.face(30), fgcolor = Q.INK2 }
        t:paintTo(canvas, math.floor((W - t:getSize().w) / 2), ty + th + Q.px(28))
        t:free()
    end
    return canvas
end

-- The sleep screen -----------------------------------------------------------------------------------------------

M.last = nil -- { mode, shown, ms }: what the last sleep showed and how long it took to make (for checks)

-- The image to sleep on (an 8-bit grey blitbuffer the size of the panel, the caller's to free), and what it is.
function M.image(ui)
    local t0 = time.now()
    local mode, bb, shown = M.mode(), nil, nil
    if mode == "frosted" or mode == "cover" then
        local ok, res = pcall(mode == "frosted" and M.frosted or M.bookCover, ui)
        if ok and res then
            bb, shown = res, mode
        elseif not ok then
            logger.warn("quiet sleep:", mode, "failed:", res)
        end
    end
    if not bb then
        local id = M.isQuiet(mode) and (M.shuffle() and M.shuffleNext() or mode) or M.DEFAULT
        bb, shown = M.quietCover(id, M.dark()), id
        if not bb and id ~= M.DEFAULT then bb, shown = M.quietCover(M.DEFAULT, false), M.DEFAULT end
    end
    local ms = time.to_ms(time.since(t0))
    M.last = { mode = mode, shown = shown, ms = ms }
    logger.info(string.format("quiet sleep: %s (%s) ready in %d ms", tostring(shown), mode, ms))
    return bb, shown
end

math.randomseed(os.time())

return M
