--[[
Quiet currently reading: Home's Currently Reading card says how far you are and how long you've really read.

  - Under a plain progress bar: "5% done", then "42 min read · 5 h 14 min left" (change 019 turns on SimpleUI's
    percent line, its time-read element and the plain bar). The numbers come from quiet_readtime.lua, the same
    as the reader's footer, the Library and Stats: time idling on a page doesn't count, and "left" runs to the
    end of the story, not the notes and index after it. A finished book's card says "Finished".
  - A finished book makes way: the card shows the most recent book you haven't finished (as the Stats page
    does). KOReader's help pages never count as a book.

SimpleUI keeps these in local functions of its module_currently.lua, so right after the plugins load this
swaps three of them inside that module (fetchBookStats, fmtTime, and its translate function for the one
"%d%% Read" string) and wraps the books prefetch. If SimpleUI changes shape, it logs and leaves the card alone.
]]

local PluginLoader = require("pluginloader")
local logger = require("logger")

local function upvalue(fn, name)
    local i = 1
    while true do
        local n, v = debug.getupvalue(fn, i)
        if not n then return nil end
        if n == name then return i, v end
        i = i + 1
    end
end

local function swap(fn, name, make)
    local i, v = upvalue(fn, name)
    if not i or type(v) ~= "function" then
        logger.warn("quiet currently: SimpleUI has no", name, "- left as it is")
        return false
    end
    debug.setupvalue(fn, i, make(v))
    return true
end

local function isBook(fp)
    return fp and not fp:find("/koreader/help/", 1, true)
end

local card_finished = false

local function patchCard(MC)
    local build = MC.build
    if type(build) ~= "function" or MC._quiet then return end
    MC._quiet = true

    -- honest numbers: SimpleUI shows days, total_secs ("read") and avg_time x pages left ("left")
    swap(build, "fetchBookStats", function(orig)
        return function(md5, shared_conn, ctx, force)
            if not md5 then return orig(md5, shared_conn, ctx, force) end
            local ok, info = pcall(function()
                local RT = require("quiet_readtime")
                local file = (ctx and ctx.current_fp) or RT.fileForMd5(md5)
                return file and RT.forFile(file, { conn = shared_conn })
            end)
            if not ok or not info then
                if not ok then logger.warn("quiet currently:", info) end
                return orig(md5, shared_conn, ctx, force)
            end
            -- SimpleUI works out "left" as avg_time x the book's pages left; hand it the pace that gives our
            -- story-end figure (a tiny one hides "left" once the story is done)
            local avg = info.pace
            local pages_left = info.pages and info.pct and info.pages * (1 - info.pct)
            if info.left_secs and pages_left and pages_left > 0 then
                avg = math.max(1e-6, info.left_secs / pages_left)
            end
            return { days = info.days or 0, total_secs = info.read_secs or 0, avg_time = avg }
        end
    end)

    swap(build, "fmtTime", function()
        return function(secs) return require("quiet_readtime").format(secs) end
    end)

    swap(build, "_", function(orig)
        return function(s, ...)
            if s == "%d%% Read" then return card_finished and "Finished" or "%d%% done" end
            return orig(s, ...)
        end
    end)

    MC.build = function(w, ctx)
        card_finished = false
        if ctx and ctx.current_fp then
            local ok, status = pcall(function()
                return require("ui/widget/booklist").getBookStatus(ctx.current_fp)
            end)
            card_finished = ok and status == "complete"
        end
        return build(w, ctx)
    end
end

-- Currently Reading = the most recent unfinished book. SimpleUI takes the first book in KOReader's history, so
-- for its prefetch the history is shown with that book first (put back straight after).
local function patchPrefetch(SH)
    local prefetch = SH.prefetchBooks
    if type(prefetch) ~= "function" or SH._quiet then return end
    SH._quiet = true
    SH.prefetchBooks = function(show_currently, show_recent, max_recent, opts)
        local RH = package.loaded["readhistory"]
        local hist = RH and RH.hist
        if not show_currently or type(hist) ~= "table" or #hist < 2 then
            return prefetch(show_currently, show_recent, max_recent, opts)
        end
        local first, pick
        local ok = pcall(function()
            local lfs = require("libs/libkoreader-lfs")
            local BookList = require("ui/widget/booklist")
            for i, e in ipairs(hist) do
                local fp = e.file
                if fp and lfs.attributes(fp, "mode") == "file" then
                    first = first or i
                    if isBook(fp) and BookList.getBookStatus(fp) ~= "complete" then
                        pick = i
                        break
                    end
                end
            end
        end)
        if not ok or not first or not pick or pick == first then
            return prefetch(show_currently, show_recent, max_recent, opts)
        end
        local reordered = { hist[pick] }
        for i, e in ipairs(hist) do
            if i ~= pick then reordered[#reordered + 1] = e end
        end
        RH.hist = reordered
        local ok2, res = pcall(prefetch, show_currently, show_recent, max_recent, opts)
        RH.hist = hist
        if not ok2 then error(res) end
        return res
    end
end

local loadPlugins = PluginLoader.loadPlugins
PluginLoader.loadPlugins = function(self)
    local first = self.enabled_plugins == nil
    local enabled, disabled = loadPlugins(self)
    if first then
        local ok, MC = pcall(require, "modules/module_currently")
        if ok and type(MC) == "table" then
            local ok2, err = pcall(patchCard, MC)
            if not ok2 then logger.warn("quiet currently: card not patched", err) end
        end
        local okS, SH = pcall(require, "modules/module_books_shared")
        if okS and type(SH) == "table" then
            local ok3, err = pcall(patchPrefetch, SH)
            if not ok3 then logger.warn("quiet currently: prefetch not patched", err) end
        end
    end
    return enabled, disabled
end
