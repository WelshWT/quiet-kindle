--[[
All Kindle Store books, as a sheet over Home (opened from the Store card's title or chevron): cover, title,
author and Amazon's own progress for each; tap a book to open it in Amazon's reader. The last row leaves for
Amazon's own home, to shop (Amazon's side only for buying books); no automatic return from there.

A sheet, not a SimpleUI screen: it's a quick chooser over Home like the Light sheet, gone with a tap outside or a
swipe down, and it adds no new place to navigate back from.
]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local Q = require("quiet_ui")
local Sheet = require("quiet_sheet")
local Store = require("qh_store")
local U = require("qh_ui")

local px = Q.px
local ROW_H, COVER_W, COVER_H = 150, 72, 108

-- One book row, painted directly (cover, title, author, progress).
local Row = Widget:extend{ w = 0, h = 0, book = nil }

function Row:getSize() return Geom:new{ w = self.w, h = self.h } end

function Row:paintTo(bb, x, y)
    local book = self.book
    local cw, ch = px(COVER_W), px(COVER_H)
    U.paintCover(bb, book.cover, x + px(12), y + math.floor((self.h - ch) / 2), cw, ch)
    local tx = x + px(12) + cw + px(28)
    local max_w = self.w - (tx - x) - px(16)
    local title = U.titleText(book.title, 33, max_w)
    local author = book.authors ~= "" and Q.text(book.authors, 28, { color = Q.INK2, max_width = max_w }) or nil
    local status, pct = U.amazonStatus(book)
    local stext = status and Q.text(status, 26, { color = Q.INK2 }) or nil
    local th = title:getSize().h
    local ah = author and author:getSize().h or 0
    local sh = stext and (stext:getSize().h + px(8)) or 0
    local ty = y + math.floor((self.h - th - ah - sh) / 2)
    title:paintTo(bb, tx, ty)
    if author then author:paintTo(bb, tx, ty + th) end
    if stext then
        local sy = ty + th + ah + px(8)
        local pill_w, pill_h = px(160), px(10)
        U.paintPill(bb, tx, sy + math.floor((stext:getSize().h - pill_h) / 2), pill_w, pill_h, pct)
        stext:paintTo(bb, tx + pill_w + px(16), sy)
    end
    title:free()
    if author then author:free() end
    if stext then stext:free() end
end

local List = Sheet:extend{ anchor = "bottom", page = 1, books = nil }

function List:open(book)
    self:close()
    UIManager:nextTick(function() Store.open(book) end)
end

function List:build()
    local W, H = self.W, self.H
    local inner = W - 2 * px(56)
    local books = self.books or {}

    local close = Q.Tap:new{ w = px(90), h = px(90), content = Q.icon("close", 44), callback = function() self:close() end }
    local n = #books
    local sub = n == 0 and "None on this Kindle" or
        ((n == 1 and "1 book" or (n .. " books")) .. " that open in Amazon's reader")
    local header = OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = px(100) },
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(100) },
            HorizontalGroup:new{ align = "center", U.icon("cart", 52), Q.hspan(20),
                VerticalGroup:new{ align = "left", Q.text("Kindle Store books", 35, { bold = true }),
                    Q.text(sub, 27, { color = Q.INK2 }) } } },
        RightContainer:new{ dimen = Geom:new{ w = inner, h = px(100) }, close },
    }

    -- as many rows as fit in 90% of the screen; pages beyond that
    local fixed = px(22 + 10 + 14 + 100 + 12 + 24 + 4 + 120)
    local pager_h = px(96)
    local per_page = math.max(1, math.floor((H * 0.9 - fixed) / px(ROW_H)))
    local pages = math.max(1, math.ceil(n / per_page))
    if pages > 1 then per_page = math.max(1, math.floor((H * 0.9 - fixed - pager_h) / px(ROW_H))) end
    pages = math.max(1, math.ceil(n / per_page))
    self.page = math.max(1, math.min(self.page, pages))

    local rows = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * per_page + 1
    for i = first, math.min(n, first + per_page - 1) do
        local book = books[i]
        rows[#rows + 1] = Q.Tap:new{
            w = inner, h = px(ROW_H), capsule_radius = 32,
            content = Row:new{ w = inner, h = px(ROW_H), book = book },
            callback = function() self:open(book) end,
        }
    end

    self.content = VerticalGroup:new{
        align = "center",
        Q.vspan(22), Sheet.grip(), Q.vspan(14), header, Q.vspan(12), rows,
    }
    if pages > 1 then
        local function turn(d)
            return function()
                self.page = math.max(1, math.min(self.page + d, pages))
                self:refresh()
            end
        end
        self.content[#self.content + 1] = CenterContainer:new{
            dimen = Geom:new{ w = inner, h = pager_h },
            HorizontalGroup:new{ align = "center",
                Q.Tap:new{ w = px(110), h = px(90), content = Q.icon("prev", 48), callback = turn(-1) },
                Q.hspan(24), Q.text(self.page .. " of " .. pages, 29), Q.hspan(24),
                Q.Tap:new{ w = px(110), h = px(90), content = Q.icon("next", 48), callback = turn(1) },
            },
        }
    end
    -- Shopping is the one reason to visit Amazon's side: say so, and how to come back.
    local shop_text = VerticalGroup:new{ align = "left", Q.text("Shop in the Kindle Store", 33),
        Q.text("Opens Amazon's home; KOReader is in its Library", 26, { color = Q.INK2 }) }
    local shop = OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = px(120) },
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(120) },
            HorizontalGroup:new{ align = "center", Q.hspan(12), U.icon("cart", 52), Q.hspan(28), shop_text } },
        RightContainer:new{ dimen = Geom:new{ w = inner, h = px(120) }, U.icon("chevron", 40) },
    }
    local Divider = Widget:extend{}
    function Divider:getSize() return Geom:new{ w = inner, h = px(4) } end
    function Divider:paintTo(bb, x, y) bb:paintRect(x, y + px(1), inner, px(2), Q.TRACK) end
    self.content[#self.content + 1] = Divider:new{}
    self.content[#self.content + 1] = Q.Tap:new{ w = inner, h = px(120), capsule_radius = 32, content = shop,
        callback = function()
            self:close()
            UIManager:nextTick(function() Store.exitToAmazon() end)
        end }
    self.content[#self.content + 1] = Q.vspan(24)
    self.panel_h = self.content:getSize().h + px(6)
    self.content = CenterContainer:new{ dimen = Geom:new{ w = W, h = self.panel_h }, self.content }
end

local host = { sheet = nil }

function host:closeSheet(s)
    if self.sheet == s then self.sheet = nil end
    UIManager:close(s, "ui", s.dimen)
end

local L = {}

function L.show()
    if host.sheet then return end
    local ok, sheet = pcall(function()
        return List:new{ plugin = host, books = Store.amazonBooks() }
    end)
    if not ok then
        logger.warn("quiethome: store list failed:", sheet)
        return
    end
    host.sheet = sheet
    UIManager:show(sheet, "ui")
end

return L
