--[[
Light sheet (swipe down from the top edge, or the handle in the toolbar): brightness and warmth, and four
labelled buttons: Wi-Fi (hold it to pick a network), Night, Rotate, Sleep. It stops short of half the screen so
the light can be judged against the text below.
]]

local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local datetime = require("datetime")
local Q = require("quiet_ui")
local Sheet = require("quiet_sheet")

local Light = Sheet:extend{ anchor = "top" }

local function powerd() return Device:getPowerDevice() end

function Light:setIntensity(i)
    local p = powerd()
    i = math.max(p.fl_min, math.min(math.floor(i + 0.5), p.fl_max))
    p:setIntensity(i)
    self:refresh()
end

-- KOReader reports and takes warmth as 0-100 (percent), whatever the hardware's own scale is.
function Light:setWarmth(w)
    local p = powerd()
    w = math.max(0, math.min(math.floor(w + 0.5), 100))
    p:setWarmth(w)
    self:refresh()
end

function Light:build()
    local W, px = self.W, Q.px
    local inner = W - 2 * px(56)
    local p = powerd()

    local now = os.time()
    local header = OverlapGroup:new{
        dimen = Geom:new{ w = inner, h = px(60) },
        LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(60) }, Q.text((os.date("%A %d %B", now):gsub(" 0", " ")), 31, { bold = true }) },
        RightContainer:new{ dimen = Geom:new{ w = inner, h = px(60) },
            Q.text(datetime.secondsToHour(now, G_reader_settings:isTrue("twelve_hour_clock")) .. "  ·  " .. (p:getCapacity() or 0) .. "%", 31) },
    }

    local function sliderBlock(label, value, min, max, small_icon, big_icon, set, extra)
        local span = max - min
        local v = span > 0 and (value - min) / span or 0
        local step = span >= 50 and 5 or 1
        local right = Q.text(tostring(value), 31, { color = Q.INK2 })
        if extra then right = HorizontalGroup:new{ align = "center", extra, Q.hspan(18), right } end
        local row = OverlapGroup:new{
            dimen = Geom:new{ w = inner, h = px(64) },
            LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(64) }, Q.text(label, 33, { bold = true }) },
            RightContainer:new{ dimen = Geom:new{ w = inner, h = px(64) }, right },
        }
        local slider = HorizontalGroup:new{
            align = "center",
            Q.Tap:new{ w = px(118), h = px(118), content = Q.icon(small_icon, 44),
                callback = function() set(value - step) end, hold_callback = function() set(min) end },
            Q.Track:new{ w = inner - 2 * px(118), h = px(118), value = v, track_h = 12, knob = 60,
                on_set = function(nv) set(min + nv * span) end },
            Q.Tap:new{ w = px(118), h = px(118), content = Q.icon(big_icon, 58),
                callback = function() set(value + step) end, hold_callback = function() set(max) end },
        }
        return VerticalGroup:new{ align = "left", row, slider }
    end

    local blocks = VerticalGroup:new{ align = "left" }
    if Device:hasFrontlight() then
        -- Auto: the light follows the room (patches/2-quiet-light.lua); moving the slider teaches it.
        local auto_chip
        local ok_a, Auto = pcall(require, "quiet_autolight")
        if ok_a and type(Auto) == "table" and Auto.setOn then
            local on = Auto.isOn()
            local label = HorizontalGroup:new{
                align = "center",
                Q.Dot:new{ size = 16, on = on }, Q.hspan(10), Q.text("Auto", 28, { bold = on, color = on and Q.INK or Q.INK2 }),
            }
            local chip_w, chip_h = px(150), px(60)
            auto_chip = Q.Tap:new{
                w = chip_w, h = chip_h,
                content = Q.Panel:new{ w = chip_w, h = chip_h, radii = { 99, 99, 99, 99 },
                    border = on and Q.INK2 or Q.LINE, bw = px(3), fill = on and Q.SOFT or nil,
                    content = CenterContainer:new{ dimen = Geom:new{ w = chip_w, h = chip_h }, label } },
                callback = function()
                    Auto.setOn(not Auto.isOn())
                    self:refresh()
                end,
            }
        end
        blocks[#blocks + 1] = sliderBlock("Brightness", p:frontlightIntensity(), p.fl_min, p.fl_max, "sun_small", "sun",
            function(i) self:setIntensity(i) end, auto_chip)
    end
    if Device:hasNaturalLight() then
        blocks[#blocks + 1] = Q.vspan(10)
        blocks[#blocks + 1] = sliderBlock("Warmth", p:frontlightWarmth(), 0, 100,
            "cool", "warm", function(w) self:setWarmth(w) end)
    end

    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    local wifi_on = ok_nm and NetworkMgr:isWifiOn()
    local night_on = G_reader_settings:isTrue("night_mode")
    local gap = px(22)
    local tile_w = math.floor((inner - 3 * gap) / 4)
    local function tile(icon, label, on, cb, hold)
        local panel = Q.Panel:new{
            w = tile_w, h = px(150), radii = { 40, 40, 40, 40 },
            border = on and Q.INK2 or Q.LINE, bw = on and px(5) or px(3), fill = on and Q.SOFT or nil,
            content = CenterContainer:new{ dimen = Geom:new{ w = tile_w, h = px(150) },
                Q.iconLabel(icon, label, { label_px = 27, bold = on }) },
        }
        return Q.Tap:new{ w = tile_w, h = px(150), content = panel, callback = cb, hold_callback = hold }
    end
    local tiles = HorizontalGroup:new{
        align = "center",
        tile("wifi", "Wi-Fi", wifi_on, function()
            if not ok_nm then return end
            local done = function() UIManager:scheduleIn(1, function() self:refresh() end) end
            if NetworkMgr:isWifiOn() then NetworkMgr:toggleWifiOff(done) else NetworkMgr:toggleWifiOn(done) end
        end, function()
            if not ok_nm then return end
            self:close()
            if NetworkMgr:isWifiOn() then NetworkMgr:reconnectOrShowNetworkMenu(nil, true)
            else NetworkMgr:toggleWifiOn(nil, true, true) end
        end),
        Q.hspan(22),
        tile("contrast", "Night", night_on, function()
            self:close()
            UIManager:nextTick(function() self.ui:handleEvent(Event:new("ToggleNightMode")) end)
        end),
        Q.hspan(22),
        tile("rotate", "Rotate", false, function()
            self:close()
            UIManager:nextTick(function() self.ui:handleEvent(Event:new("SwapRotation")) end)
        end),
        Q.hspan(22),
        tile("sleep", "Sleep", false, function()
            self:close()
            UIManager:nextTick(function() UIManager:suspend() end)
        end),
    }

    -- Sleep screen: what the Kindle shows while it sleeps (quiet_sleepsheet), as a row like the More sheet's, with
    -- the current choice on the right
    local sleep_row
    local ok_sl, Sleep = pcall(require, "quiet_sleep")
    if ok_sl then
        local rh = px(96)
        local og = OverlapGroup:new{
            dimen = Geom:new{ w = inner, h = rh },
            LeftContainer:new{ dimen = Geom:new{ w = inner, h = rh },
                HorizontalGroup:new{ align = "center", Q.hspan(8), Q.icon("sleep", 44), Q.hspan(22),
                    Q.text("Sleep screen", 29) } },
            RightContainer:new{ dimen = Geom:new{ w = inner, h = rh },
                HorizontalGroup:new{ align = "center", Q.text(Sleep.summary() or "", 27, { color = Q.INK2 }),
                    Q.hspan(10), Q.icon("chevron", 36), Q.hspan(4) } },
        }
        sleep_row = Q.Tap:new{ w = inner, h = rh, content = og, capsule_radius = 32, callback = function()
            local host, ui = self.plugin, self.ui
            self:close()
            UIManager:nextTick(function()
                local ok_s, SleepSheet = pcall(require, "quiet_sleepsheet")
                if ok_s then SleepSheet.open(host, ui) end
            end)
        end }
    end

    local closer = Q.Tap:new{ w = px(200), h = px(60), content = Q.icon("up", 44), callback = function() self:close() end }
    local bottom = closer
    if self.classic_menu then
        -- On Home, Library and Stats this sheet replaces KOReader's classic menu; keep that one tap away.
        local link = Q.Tap:new{
            w = px(380), h = px(60),
            content = Q.text("All KOReader settings", 26, { color = Q.INK2 }),
            callback = function()
                self:close()
                UIManager:nextTick(self.classic_menu)
            end,
        }
        -- ...and Amazon's own side (Kindle home, the Store, Amazon's settings) one tap away too, on the right.
        local amazon = Q.Tap:new{
            w = px(300), h = px(60),
            content = HorizontalGroup:new{ align = "center",
                Q.text("Kindle home", 26, { color = Q.INK2 }), Q.hspan(10), Q.icon("leave", 30) },
            callback = function()
                self:close()
                UIManager:nextTick(Light.leaveForKindleHome)
            end,
        }
        bottom = OverlapGroup:new{
            dimen = Geom:new{ w = inner, h = px(60) },
            LeftContainer:new{ dimen = Geom:new{ w = inner, h = px(60) }, link },
            CenterContainer:new{ dimen = Geom:new{ w = inner, h = px(60) }, closer },
            RightContainer:new{ dimen = Geom:new{ w = inner, h = px(60) }, amazon },
        }
    end
    self.content = VerticalGroup:new{
        align = "center",
        Q.vspan(22), header, Q.vspan(18), blocks, Q.vspan(26), tiles, Q.vspan(12),
    }
    if sleep_row then
        self.content[#self.content + 1] = sleep_row
        self.content[#self.content + 1] = Q.vspan(4)
    end
    self.content[#self.content + 1] = bottom
    self.content[#self.content + 1] = Q.vspan(6)
    self.panel_h = self.content:getSize().h + px(6)
    self.content = CenterContainer:new{ dimen = Geom:new{ w = W, h = self.panel_h }, self.content }
end

-- Leave KOReader for Amazon's Kindle home (no automatic return: you chose Amazon's side). quiet_amazon knows
-- the direct way; without it, the same Exit the old Store row sent.
function Light.leaveForKindleHome()
    local ok, Amazon = pcall(require, "quiet_amazon")
    if ok and type(Amazon) == "table" and Amazon.openHome and pcall(Amazon.openHome) then return end
    local okd, Dispatcher = pcall(require, "dispatcher")
    if okd and Dispatcher.execute and pcall(Dispatcher.execute, Dispatcher, { exit = true }) then return end
    UIManager:broadcastEvent(Event:new("Exit"))
end

-- The automatic light moved the brightness while this sheet is open: show where it is now.
function Light:onQuietLightChanged()
    self:refresh()
end

return Light
