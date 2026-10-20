--[[
Shared drawing for the Kindle Store card and its list: Amazon's cover images as rounded covers (the same shape
as every other cover), icons from icons/quiet/, and short titles.
]]

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local IconWidget = require("ui/widget/iconwidget")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Q = require("quiet_ui")

local U = {}

if not Q.icon_dir and package.searchpath then
    local p = package.searchpath("quiet_ui", package.path)
    if p then Q.icon_dir = p:gsub("quiet_ui%.lua$", "") .. "icons/" end
end

local data_dir = DataStorage.getFullDataDir and DataStorage:getFullDataDir() or DataStorage:getDataDir()
U.ICONS = data_dir .. "/icons/quiet/"

local COVER_EDGE = Blitbuffer.gray(0.30)

function U.icon(name, size)
    return IconWidget:new{ file = U.ICONS .. name .. ".svg", width = Q.px(size), height = Q.px(size), alpha = true }
end

function U.paintIcon(bb, name, size, x, y)
    local icon = U.icon(name, size)
    icon:paintTo(bb, x, y)
    icon:free()
end

-- Same radius rule as the covers in patches/2-quiet-soft.lua.
function U.coverRadius(w, h)
    return math.max(8, math.min(18, math.floor(math.min(w, h) * 0.06 + 0.5)))
end

-- Amazon's cover image scaled to fill w x h (cropped in the middle), kept for the life of KOReader.
local covers = {}
function U.coverBB(path, w, h)
    if not path then return nil end
    local k = path .. "|" .. w .. "x" .. h
    if covers[k] ~= nil then return covers[k] or nil end
    covers[k] = false
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local RenderImage = require("ui/renderimage")
    local ok, src = pcall(RenderImage.renderImageFile, RenderImage, path, false)
    if not ok or not src then
        logger.warn("quiethome: cover not readable:", path)
        return nil
    end
    local sw, sh = src:getWidth(), src:getHeight()
    local f = math.max(w / sw, h / sh)
    local tw, th = math.max(w, math.ceil(sw * f)), math.max(h, math.ceil(sh * f))
    local scaled = RenderImage:scaleBlitBuffer(src, tw, th)
    local out = Blitbuffer.new(w, h, scaled:getType())
    out:blitFrom(scaled, 0, 0, math.floor((tw - w) / 2), math.floor((th - h) / 2), w, h)
    scaled:free()
    src:free()
    covers[k] = out
    return out
end

local function maskCorners(bb, x, y, w, h, r, color)
    for row = 0, r - 1 do
        local yy = r - row - 0.5
        local inset = math.floor(r - math.sqrt(math.max(0, r * r - yy * yy)) + 0.5)
        if inset > 0 then
            bb:paintRect(x, y + row, inset, 1, color)
            bb:paintRect(x + w - inset, y + row, inset, 1, color)
            bb:paintRect(x, y + h - 1 - row, inset, 1, color)
            bb:paintRect(x + w - inset, y + h - 1 - row, inset, 1, color)
        end
    end
end

-- A rounded cover with a thin soft edge; a plain soft tile when there's no image.
function U.paintCover(bb, path, x, y, w, h)
    local r = U.coverRadius(w, h)
    local img = U.coverBB(path, w, h)
    if img then
        bb:blitFrom(img, x, y, 0, 0, w, h)
        maskCorners(bb, x, y, w, h, r, Q.PAPER)
        bb:paintBorder(x, y, w, h, math.max(1, Q.px(2)), COVER_EDGE, r, 1)
    else
        Q.fillRound(bb, x, y, w, h, Q.TRACK, r, r, r, r)
    end
end

-- "A Parade of Horribles: Dungeon Crawler Carl, Book 8" -> "A Parade of Horribles", for when the whole title
-- doesn't fit on one line.
function U.mainTitle(title)
    local main = tostring(title or ""):match("^(.-):%s")
    if main and #main >= 3 then return main end
    return title
end

-- A one-line title: the whole title if it fits, else the part before the subtitle, else cut with "…".
function U.titleText(title, px, max_w, opts)
    opts = opts or {}
    local tw = Q.text(title, px, { bold = opts.bold ~= false, color = opts.color })
    if tw:getSize().w <= max_w then return tw end
    tw:free()
    return Q.text(U.mainTitle(title), px, { bold = opts.bold ~= false, color = opts.color, max_width = max_w })
end

local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
    "November", "December" }

-- Month of a unix time or a "YYYY-MM-DD" date; the year is added when it isn't this year.
function U.monthOf(when)
    local y, m
    if type(when) == "number" then
        local t = os.date("*t", when)
        y, m = t.year, t.month
    else
        local ys, ms = tostring(when or ""):match("^(%d%d%d%d)%-(%d%d)")
        y, m = tonumber(ys), tonumber(ms)
    end
    local name = m and MONTHS[m]
    if not name then return nil end
    if y ~= tonumber(os.date("%Y")) then name = name .. " " .. y end
    return name
end

-- "43%", "Finished · October", or nil (never opened).
-- When Amazon's reader finished a book: the date recorded for the Stats page (qs_amazon_finished.lua, read before
-- anything reopened them), else Amazon's last-opened time, which moves whenever the book is opened again.
local finished_on
local function norm(s) return (s or ""):lower():gsub("[^%w]", "") end
local function recordedFinish(title)
    if finished_on == nil then
        finished_on = {}
        local ok, list = pcall(require, "qs_amazon_finished")
        for _, e in ipairs(ok and type(list) == "table" and list or {}) do
            local key = norm(e.title)
            if key ~= "" and (not finished_on[key] or e.finished > finished_on[key]) then finished_on[key] = e.finished end
        end
    end
    local t = norm(title)
    for key, date in pairs(finished_on) do
        if t:sub(1, #key) == key then return date end
    end
end

function U.amazonStatus(book)
    if book.finished then
        local when = recordedFinish(book.title) or book.last_opened
        local month = when and U.monthOf(when)
        return month and ("Finished \u{00B7} " .. month) or "Finished", 1
    end
    if book.pct and book.pct > 0 then
        return string.format("%d%%", math.max(1, math.floor(book.pct * 100))), book.pct
    end
    return nil
end

-- Pill-shaped progress bar (same greys as the soft progress bars).
U.PILL_TRACK = Blitbuffer.gray(0.15)
U.PILL_FILL = Blitbuffer.gray(0.75)
function U.paintPill(bb, x, y, w, h, pct)
    local r = math.floor(h / 2)
    Q.fillRound(bb, x, y, w, h, U.PILL_TRACK, r, r, r, r)
    local fw = math.floor(w * math.max(0, math.min(pct or 0, 1)))
    if fw > 0 then Q.fillRound(bb, x, y, math.max(fw, h), h, U.PILL_FILL, r, r, r, r) end
end

return U
