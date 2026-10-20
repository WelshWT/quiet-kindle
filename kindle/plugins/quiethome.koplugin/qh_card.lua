--[[
Home: the "Kindle Store books" card, a SimpleUI module (change 018 puts it where the old Store row was).

    [cart]  Kindle Store books          [cover][cover][cover][cover][cover][cover]   >
            8 books in Amazon's reader

Each cover opens that book in Amazon's reader; the rest of the card (title, chevron) opens the list of all of
them (qh_list). One band, not the mockup's three rows: Home has ~250 px left under Collections (measured
2026-10-19), and a taller card would push it onto a second Home page.
]]

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Q = require("quiet_ui")
local Store = require("qh_store")
local U = require("qh_ui")

local px = Q.px

local M = {
    id = "quiet_store",
    name = "Kindle Store books (Quiet)",
    label = nil,
    enabled_key = "quiet_store_enabled",
    default_on = false,
    has_covers = true,
}

local CARD_H = 158
local PAD_X, ICON, ICON_GAP = 26, 52, 18
local COVER_W, COVER_H, COVER_GAP = 80, 120, 12
local CHEVRON = 40

local Card = InputContainer:extend{ w = 0, h = 0, books = nil }

function Card:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.w, h = self.h }
    self.ges_events = {
        TapStoreCard = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
    self.targets = {}
end

function Card:getSize() return Geom:new{ w = self.w, h = self.h } end

function Card:subtitle()
    local n = #self.books
    if n == 0 then return "Amazon's own books" end
    return (n == 1 and "1 book" or (n .. " books")) .. " in Amazon's reader"
end

function Card:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.targets = {}
    local w, h = self.w, self.h
    local r, b = Q.R_DIALOG, px(3)
    Q.fillRound(bb, x, y, w, h, Q.LINE, r, r, r, r)
    Q.fillRound(bb, x + b, y + b, w - 2 * b, h - 2 * b, Q.PAPER, r - b, r - b, r - b, r - b)

    local ok, err = pcall(function()
        -- left: cart, title, count
        local ix = x + px(PAD_X)
        U.paintIcon(bb, "cart", ICON, ix, y + math.floor((h - px(ICON)) / 2))
        local tx = ix + px(ICON) + px(ICON_GAP)
        local title = Q.text("Kindle Store books", 35, { bold = true })
        local sub = Q.text(self:subtitle(), 27, { color = Q.INK2 })
        local th, sh = title:getSize().h, sub:getSize().h
        local ty = y + math.floor((h - th - sh) / 2)
        title:paintTo(bb, tx, ty)
        sub:paintTo(bb, tx, ty + th)
        local text_end = tx + math.max(title:getSize().w, sub:getSize().w)
        title:free()
        sub:free()

        -- right: chevron
        local cx = x + w - px(PAD_X) - px(CHEVRON)
        U.paintIcon(bb, "chevron", CHEVRON, cx, y + math.floor((h - px(CHEVRON)) / 2))

        -- covers, right-aligned before the chevron, as many as fit
        local cw, ch, gap = px(COVER_W), px(COVER_H), px(COVER_GAP)
        local right = cx - px(20)
        local room = right - (text_end + px(28))
        local n = math.min(#self.books, math.max(0, math.floor((room + gap) / (cw + gap))))
        local cy = y + math.floor((h - ch) / 2)
        local start = right - (n * cw + math.max(0, n - 1) * gap)
        for i = 1, n do
            local book = self.books[i]
            local bx = start + (i - 1) * (cw + gap)
            U.paintCover(bb, book.cover, bx, cy, cw, ch)
            self.targets[#self.targets + 1] = { x = bx - x - math.floor(gap / 2), y = 0, w = cw + gap, h = h, book = book }
        end
    end)
    if not ok then logger.warn("quiethome: card paint failed:", err) end
end

function Card:onTapStoreCard(_, ges)
    local rx, ry = ges.pos.x - self.dimen.x, ges.pos.y - self.dimen.y
    for _, t in ipairs(self.targets) do
        if rx >= t.x and rx < t.x + t.w and ry >= t.y and ry < t.y + t.h then
            local book = t.book
            UIManager:nextTick(function() Store.open(book) end)
            return true
        end
    end
    UIManager:nextTick(function() require("qh_list").show() end)
    return true
end

function M.build(w, ctx)
    local ok, books = pcall(Store.amazonBooks)
    if not ok then
        logger.warn("quiethome: no Amazon books:", books)
        books = {}
    end
    return Card:new{ w = w, h = px(CARD_H), books = books }
end

function M.getHeight() return px(CARD_H) end

function M.getMenuItems() return nil end

return M
