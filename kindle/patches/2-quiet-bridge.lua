--[[
Quiet bridge: lets Claude (over SSH) ask KOReader to do things safely, by writing one line to /tmp/quiet-cmd.

    restart        save the open book and settings, restart KOReader, then reopen the same book
    flush          ask KOReader to save all settings now (its own writes don't report a failure, so the answer only
                   says it was asked)
    status         write what's on screen to /tmp/quiet-ack ("reader <file>" or "home")
    lua <code>     (debugging) run Lua inside KOReader and answer with the result
    open <file>    open a book (answered once it is open, or with an error if KOReader didn't open it)
    event <Name>   broadcast a KOReader event, e.g. "event SimpleUIGoHomescreen" or "event ShowToc" (answered once it
                   is sent; whether anything acted on it isn't known)

Every command is answered in /tmp/quiet-ack, or in /tmp/quiet-ack.<id> when the line starts with "@<id> " (bin/kcmd
does that, so two senders never read each other's answers). /tmp/quiet-ready holds the time KOReader last started.
Runs as a "late" user patch: after UIManager exists, before the home screen or a book opens.

Taking a request renames it first (review C1-5): a sender can publish the next one meanwhile without it being
deleted unread, and a line still being written in place is read again a moment later instead of being lost.
A request is a whole line: one whose newline hasn't come within 2 s is answered with an error and never run
(review C1-18, C1-25). Answers and marks are written in one step (temp file, then rename), so nobody reads half
of one.

This check is the only thing that wakes KOReader while you read (measured: 15 wake-ups per 30 s, all of them
this poll), so it looks every 2 s only while Claude is working (start-up, or a command in the last 10 minutes)
and every 20 s otherwise. bin/kcmd waits long enough for either.
]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local CMD, ACK, READY, REOPEN = "/tmp/quiet-cmd", "/tmp/quiet-ack", "/tmp/quiet-ready", "/tmp/quiet-reopen"
local CLAIMED = CMD .. ".claimed"
local FAST, SLOW, ACTIVE_FOR = 2, 20, 600 -- seconds
local OPEN_WAIT = 15 -- seconds an open may take before it counts as refused (with SLOW, within kcmd's 45 s wait)
local last_command = os.time()

-- Temp file, then rename: readers never see half a file, and a link planted at the name is replaced, not followed.
-- The temp file is read back before the rename, so a write that failed or came out short (a full /tmp) publishes
-- nothing (review C1-33). True when the file is in place.
local function write(path, text)
    local tmp = os.tmpname()
    local f = io.open(tmp, "w")
    if not f then return false end
    local ok = f:write(text, "\n")
    ok = f:close() and ok
    local back = ok and io.open(tmp, "r")
    ok = back and back:read("*a") == text .. "\n"
    if back then back:close() end
    if ok and os.rename(tmp, path) then return true end
    os.remove(tmp)
    logger.warn("quiet bridge: could not write", path)
    return false
end

local function openBook()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local ui = ReaderUI and ReaderUI.instance
    return ui and ui.document and ui.document.file
end

local function handle(line, ack)
    local word, rest = line:match("^%s*(%S+)%s*(.-)%s*$")
    if word == "restart" then
        local file = openBook()
        if file and not write(REOPEN, file) then
            -- without the record, the restart would come back to Home instead of the book: don't restart
            write(ack, "error could not record the open book (is /tmp full?): not restarting")
            return
        end
        write(ack, "restart " .. os.time())
        UIManager:broadcastEvent(Event:new("Restart"))
        return true
    elseif word == "flush" then
        UIManager:flushSettings()
        write(ack, "flush " .. os.time())
    elseif word == "status" then
        local file = openBook()
        write(ack, file and ("reader " .. file) or "home")
    elseif word == "open" and rest ~= "" then
        -- Answered only once KOReader has the book open: showReader() returns normally also when it refuses (no such
        -- file, a format it can't read), and opens a book later, in a coroutine (review C1-F2). It is given the
        -- resolved path, which KOReader then keeps as the open file's name, so the two compare (review C1-F4).
        local want = lfs.attributes(rest, "mode") == "file" and require("ffi/util").realpath(rest)
        if not want then
            write(ack, "error no such file: " .. rest)
            return
        end
        require("apps/reader/readerui"):showReader(want)
        local waited = 0
        local function check()
            if openBook() == want then
                write(ack, "open " .. want)
            elseif waited >= OPEN_WAIT then
                write(ack, "error KOReader did not open " .. rest .. " (showing: " .. (openBook() or "home") .. ")")
            else
                waited = waited + 0.5
                UIManager:scheduleIn(0.5, check)
            end
        end
        UIManager:scheduleIn(0.5, check)
    elseif word == "lua" and rest ~= "" then
        -- debugging from SSH only: evaluate Lua inside KOReader, answer with the result
        local fn, err = loadstring(rest)
        local res
        if fn then
            local ok
            ok, res = pcall(fn)
            if not ok then res = "error: " .. tostring(res) end
        else
            res = "syntax: " .. tostring(err)
        end
        write(ack, tostring(res))
    elseif word == "event" and rest ~= "" then
        local name, arg = rest:match("^(%S+)%s*(.-)$")
        UIManager:broadcastEvent(Event:new(name, arg ~= "" and arg or nil))
        write(ack, "event " .. name .. " " .. os.time())
    else
        write(ack, "unknown " .. tostring(word))
    end
end

local claimed_at -- a request taken but still empty: its sender may be writing it in place

local poll
poll = function()
    if not claimed_at and os.rename(CMD, CLAIMED) then claimed_at = os.time() end
    if claimed_at then
        local f = io.open(CLAIMED, "r")
        local whole = f and f:read("*a") or ""
        if f then f:close() end
        -- a request is one line ending in a newline; without it the sender is still writing, so wait (up to 2 s)
        local line = whole:match("^([^\n]*)\n")
        local age = os.time() - claimed_at
        if not line and age >= 0 and age < 2 then
            UIManager:scheduleIn(0.3, poll)
            return
        end
        os.remove(CLAIMED)
        claimed_at = nil
        if not line then
            -- still no newline after the wait: the sender died or stalled mid-line. Never run a fragment (review
            -- C1-25); say so, in the sender's own answer file when the fragment got as far as its id.
            if whole ~= "" then
                local fid = whole:match("^@([%w%-%._]+)%s")
                write(fid and (ACK .. "." .. fid) or ACK, "error incomplete request (no newline): not run")
            end
        elseif line ~= "" then
            last_command = os.time()
            local id, rest = line:match("^@([%w%-%._]+)%s+(.*)$")
            local ack = id and (ACK .. "." .. id) or ACK
            local ok, stop = pcall(handle, rest or line, ack)
            if not ok then
                logger.warn("quiet bridge:", stop)
                write(ack, "error " .. tostring(stop))
            elseif stop then
                return
            end
        end
    end
    local idle = os.time() - last_command
    UIManager:scheduleIn((idle >= 0 and idle < ACTIVE_FOR) and FAST or SLOW, poll)
end

UIManager:scheduleIn(FAST, poll)
write(READY, tostring(os.time()))

-- Amazon's status bar (JunoStatusBarDriver on firmware 5.19) keeps painting its clock and icons over KOReader every
-- minute. Pausing it and giving it back (on a clean exit, or by a crash watcher once KOReader is gone) belongs to one
-- place: patches/quiet-amazon-guard.sh, run by 2-quiet-light.lua at every start, where each step that touches it
-- holds one lock and checks which KOReader owns it. The bridge used to pause it here and keep its own crash guard;
-- two unlocked actors could race a newer KOReader's takeover and resume the bar over it (review C1-26).
-- Also drop powerd listeners orphaned by earlier hard kills.
os.execute([=[for p in $(pgrep -f "lipc-wait-event -m -s 0 com.lab12[6].powerd"); do [ "$(awk "{print \$4}" /proc/$p/stat 2>/dev/null)" = "1" ] && kill $p; done 2>/dev/null]=])

-- Whatever was painted in the moment before KOReader took over: one full refresh a few seconds after start.
UIManager:scheduleIn(4, function() UIManager:setDirty(nil, "full") end)

-- After a bridge restart, go back into the book that was open (if it is still there: a stale or damaged record
-- would only end in a "file not found" message).
local rf = io.open(REOPEN, "r")
if rf then
    local file = rf:read("*l")
    rf:close()
    os.remove(REOPEN)
    if file and file ~= "" and lfs.attributes(file, "mode") ~= "file" then
        logger.warn("quiet bridge: not reopening, no such book:", file)
    elseif file and file ~= "" then
        UIManager:scheduleIn(1.5, function()
            local ok, err = pcall(function()
                require("apps/reader/readerui"):showReader(file)
            end)
            if not ok then logger.warn("quiet bridge: reopen failed", err) end
        end)
    end
end
