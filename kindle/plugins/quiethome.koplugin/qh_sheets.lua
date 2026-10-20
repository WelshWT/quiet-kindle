--[[
Two small sheets in the Quiet style, both over the Library:

  amazon()  The Library header's "Store" button: the way to Amazon's side when it's needed. Asked for: "u just want to
            access books from ur library. but there should still be an intuitive way to go back to the amazon
            OS". Two rows, each marked with the link-out arrow because each leaves KOReader: "Shop in the Kindle
            Store" and "Kindle home & settings", and one line on how to come back.
  book(b)   Holding one of Amazon's books in the Library: what it is and where it opens, with one button to open
            it. It replaces KOReader's file menu, whose delete and rename make no sense for these.
]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local Q = require("quiet_ui")
local Sheet = require("quiet_sheet")
local Store = require("qh_store")
local U = require("qh_ui")

local px = Q.px

local host = { sheet = nil }

function host:closeSheet(s)
    if self.sheet == s then self.sheet = nil end
    UIManager:close(s, "ui", s.dimen)
end

local function show(class, fields)
    if host.sheet then host:closeSheet(host.sheet) end
    fields.plugin = host
    local ok, sheet = pcall(function() return class:new(fields) end)
    if not ok then
        logger.warn("quiethome: sheet failed:", sheet)
        return
    end
    host.sheet = sheet
    UIManager:show(sheet, "ui")
end

local Divider = Widget:extend{ w = 0 }
function Divider:getSize() return Geom:new{ w = self.w, h = px(4) } end
function Divider:paintTo(bb, x, y) bb:paintRect(x, y + px(1), self.w, px(2), Q.TRACK) end

local function header(title, inner, on_close)
    local close = Q.Tap:new{ w = px(90), h = px(90), content = Q.icon("close", 44), callback = on_close }
    return OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = px(90) },
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(90) }, Q.text(title, 37, { bold = true }) },
        RightContainer:new{ dimen = Geom:new{ w = inner, h = px(90) }, close },
    }
end

-- Leave for Amazon's side: the store, or its home. quiet_amazon (fork F's) does it properly when it can; otherwise
-- KOReader exits and the launcher shows Amazon's home, as the old Store row did.
local function goAmazon(which)
    local ok, A = pcall(require, "quiet_amazon")
    if ok and type(A) == "table" then
        local fn = which == "store" and A.openStore or A.openHome
        local can = fn ~= nil
        if can and which == "store" and A.supported then
            local ok_s, supported = pcall(A.supported)
            can = ok_s and supported
        end
        if can then
            local ok_f, err = pcall(fn)
            if ok_f then return end
            logger.warn("quiethome: quiet_amazon", which, "failed:", err)
        end
    end
    Store.exitToAmazon()
end

local AmazonSheet = Sheet:extend{ anchor = "bottom" }

function AmazonSheet:go(which)
    self:close()
    UIManager:nextTick(function() goAmazon(which) end)
end

function AmazonSheet:build()
    local W = self.W
    local inner = W - 2 * px(56)
    local function row(icon, title, subtitle, cb)
        local text = VerticalGroup:new{ align = "left", Q.text(title, 35),
            Q.text(subtitle, 27, { color = Q.INK2, max_width = inner - px(220) }) }
        local og = OverlapGroup:new{
            dimen = Geom:new{ w = inner, h = px(136) },
            LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(136) },
                HorizontalGroup:new{ align = "center", Q.hspan(12), U.icon(icon, 56), Q.hspan(28), text } },
            RightContainer:new{ dimen = Geom:new{ w = inner, h = px(136) },
                HorizontalGroup:new{ U.icon("external", 40), Q.hspan(12) } },
        }
        return Q.Tap:new{ w = inner, h = px(136), content = og, callback = cb, capsule_radius = 32 }
    end
    local back = TextBoxWidget:new{
        text = "KOReader stays in Amazon's Library: tap it there to come back.",
        face = Q.face(27), fgcolor = Q.INK2, width = inner - px(24),
    }
    self.content = VerticalGroup:new{
        align = "center",
        Q.vspan(22), Sheet.grip(), Q.vspan(14),
        header("Amazon", inner, function() self:close() end), Q.vspan(8),
        row("cart", "Shop in the Kindle Store", "Leaves KOReader for Amazon's store",
            function() self:go("store") end),
        row("kindle", "Kindle home & settings", "Leaves KOReader for Amazon's home screen",
            function() self:go("home") end),
        Q.vspan(10), Divider:new{ w = inner }, Q.vspan(18),
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = back:getSize().h }, HorizontalGroup:new{ Q.hspan(12), back } },
        Q.vspan(30),
    }
    self.panel_h = self.content:getSize().h + px(6)
    self.content = CenterContainer:new{ dimen = Geom:new{ w = W, h = self.panel_h }, self.content }
end

-- One of Amazon's books, held in the Library.
local BookSheet = Sheet:extend{ anchor = "bottom", book = nil }

local Cover = Widget:extend{ book = nil, w = 0, h = 0 }
function Cover:getSize() return Geom:new{ w = self.w, h = self.h } end
function Cover:paintTo(bb, x, y)
    U.paintCover(bb, self.book.cover, x, y, self.w, self.h)
    local ok, Lib = pcall(require, "qh_library")
    if ok then Lib.paintCoverBadge(bb, x, y, self.w, self.h) end
end

function BookSheet:build()
    local W = self.W
    local inner = W - 2 * px(56)
    local book = self.book
    local cw, ch = px(112), px(168)
    local text_w = inner - cw - px(36)
    local info = VerticalGroup:new{ align = "left", U.titleText(book.title, 35, text_w) }
    if book.authors ~= "" then info[#info + 1] = Q.text(book.authors, 29, { color = Q.INK2, max_width = text_w }) end
    local status = U.amazonStatus(book)
    if status then
        info[#info + 1] = Q.vspan(8)
        info[#info + 1] = Q.text(status .. " in Amazon's reader", 27, { color = Q.INK2, max_width = text_w })
    end
    local top = HorizontalGroup:new{ align = "center",
        Cover:new{ book = book, w = cw, h = ch }, Q.hspan(36), info }
    local about = TextBoxWidget:new{
        text = "A Kindle Store book: it opens in Amazon's reader. KOReader closes while you read it and comes back "
            .. "when you close the book.",
        face = Q.face(28), fgcolor = Q.INK2, width = inner - px(24),
    }
    local label = HorizontalGroup:new{ align = "center", Q.text("Open in Amazon's reader", 33, { bold = true }),
        Q.hspan(14), U.icon("external", 40) }
    local bw = label:getSize().w + px(88)
    local button = Q.Tap:new{
        w = bw, h = px(100),
        content = Q.Panel:new{ w = bw, h = px(100), radii = { 999, 999, 999, 999 }, border = Q.LINE, bw = px(3),
            content = CenterContainer:new{ dimen = Geom:new{ w = bw, h = px(100) }, label } },
        callback = function()
            self:close()
            UIManager:nextTick(function() Store.open(book) end)
        end,
    }
    self.content = VerticalGroup:new{
        align = "center",
        Q.vspan(22), Sheet.grip(), Q.vspan(26),
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = ch }, top },
        Q.vspan(26),
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = about:getSize().h }, HorizontalGroup:new{ Q.hspan(4), about } },
        Q.vspan(26),
        button,
        Q.vspan(34),
    }
    self.panel_h = self.content:getSize().h + px(6)
    self.content = CenterContainer:new{ dimen = Geom:new{ w = W, h = self.panel_h }, self.content }
end

local S = {}

function S.amazon() show(AmazonSheet, {}) end

function S.book(book)
    if book then show(BookSheet, { book = book }) end
end

return S
