--[[
Quiet net: HTTPS that never freezes the page.

Each request runs in a child process (ffi/util runInSubProcess). The child makes the request and passes the
response back through a pipe as it arrives; the reader checks the pipe a few times a second from UIManager's
scheduler, so pages still turn while Claude thinks, and a request can be dropped at any moment.

TLS is checked properly: the server's certificate chain against KOReader's CA bundle (data/ca-bundle.crt) and
the certificate's name against the host. LuaSec as shipped verifies neither (verify = "none").

    local req = Net.request{
        url = "https://…", method = "POST", headers = { … }, body = "…",
        stream = true,                              -- body bytes go to on_chunk as they arrive
        on_chunk = function(bytes) end,
        on_done = function(code, body, info) end,   -- any HTTP answer; body is the whole body, or with
                                                    -- stream = true its first 64 KB (enough for an error)
        on_error = function(message, info) end,     -- no HTTP answer: info.kind = "offline", "timeout",
                                                    -- "tls", "closed" or "other"
        timeout = 60,                               -- seconds without a byte before giving up
        total_timeout = 300,                        -- seconds for the whole request
    }
    req:cancel()                                    -- silent: no callback afterwards; the child is killed
    local w = Net.whenOnline(function() … end, function(message) … end)  -- Wi-Fi on first if needed, no box
    w:cancel()                                      -- stop waiting: neither function runs afterwards
    Net.cancelAll()                                 -- e.g. when the book closes
]]

local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local logger = require("logger")
local time = require("ui/time")
require("ffi/posix_h")
local C = ffi.C

local Net = {}

local POLL_FIRST, POLL_ACTIVE, POLL_IDLE_MAX = 0.05, 0.12, 0.5
local HEAD_MAX = 64 * 1024
local CA_FILES = { "data/ca-bundle.crt", "/mnt/us/koreader/data/ca-bundle.crt", "/etc/ssl/certs/ca-certificates.crt" }

-- Child side ---------------------------------------------------------------------------------------------------

function Net.caFile()
    for _, p in ipairs(CA_FILES) do
        local f = io.open(p, "r")
        if f then
            f:close()
            return p
        end
    end
end

-- The certificate must name the host: a subjectAltName DNS entry (or, without any, the common name), with
-- one leading "*." wildcard label allowed.
function Net.hostMatches(cert, host)
    if not cert then return nil, "tls: no certificate" end
    host = host:lower()
    local names = {}
    local ok, ext = pcall(cert.extensions, cert)
    local san = ok and type(ext) == "table" and ext["2.5.29.17"]
    if type(san) == "table" and type(san.dNSName) == "table" then
        for _, n in ipairs(san.dNSName) do names[#names + 1] = tostring(n):lower() end
    end
    if #names == 0 then
        local ok2, subject = pcall(cert.subject, cert)
        if ok2 and type(subject) == "table" then
            for _, e in ipairs(subject) do
                if e.oid == "2.5.4.3" or e.name == "CN" or e.name == "commonName" then
                    names[#names + 1] = tostring(e.value):lower()
                end
            end
        end
    end
    for _, n in ipairs(names) do
        if n == host then return true end
        local suffix = n:match("^%*(%.[^*]+%.[^*]+)$")
        if suffix and #host > #suffix and host:sub(-#suffix) == suffix
                and not host:sub(1, #host - #suffix):find(".", 1, true) then
            return true
        end
    end
    return nil, "tls: certificate is not for " .. host
end

-- LuaSocket "create" function for https: LuaSec's own, plus a verified chain and a name check.
local function tlsCreate(params, block_timeout)
    local socket = require("socket")
    local ssl = require("ssl")
    local try = socket.try
    return function()
        local conn = {}
        conn.sock = try(socket.tcp())
        local st = getmetatable(conn.sock).__index.settimeout
        function conn:settimeout()
            return st(self.sock, block_timeout)
        end
        function conn:connect(host, port)
            try(self.sock:connect(host, port))
            self.sock = try(ssl.wrap(self.sock, params))
            self.sock:sni(host)
            self.sock:settimeout(block_timeout)
            try(self.sock:dohandshake())
            try(Net.hostMatches(self.sock:getpeercertificate(), host))
            for name, method in pairs(getmetatable(self.sock).__index) do
                if type(method) == "function" then
                    self[name] = function(this, ...) return method(this.sock, ...) end
                end
            end
            return 1
        end
        return conn
    end
end

-- Does the request and reports through emit(kind, payload) -> ok:
--   "D" body bytes, "Z" "<code>\n<retry-after>" at the end, "E" "<error>" when there was no HTTP answer.
-- Runs in the child; tests call it directly.
function Net._perform(spec, emit)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local block_timeout = spec.block_timeout or 60
    local headers = {}
    for k, v in pairs(spec.headers or {}) do headers[k:lower()] = v end
    local body = spec.body
    if body then headers["content-length"] = tostring(#body) end
    local reqt = {
        url = spec.url,
        method = spec.method or (body and "POST" or "GET"),
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = function(chunk)
            if chunk and chunk ~= "" and not emit("D", chunk) then return nil, "reader went away" end
            return 1
        end,
    }
    if spec.url:match("^https:") then
        local cafile = Net.caFile()
        if not cafile then
            emit("E", "tls: no CA certificates")
            return
        end
        reqt.create = tlsCreate({
            mode = "client", protocol = "any",
            options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
            verify = "peer", cafile = cafile,
        }, block_timeout)
    end
    local ok, code, resp_headers = http.request(reqt)
    if not ok then
        emit("E", tostring(code))
        return
    end
    emit("Z", tostring(code) .. "\n" .. tostring(resp_headers and resp_headers["retry-after"] or ""))
end

local function writeAll(fd, data)
    local ptr = ffi.cast("const char *", data)
    local off, n = 0, #data
    while off < n do
        local w = tonumber(C.write(fd, ptr + off, n - off))
        if w < 0 then
            if ffi.errno() ~= 4 then return false end -- EINTR: try again
        else
            off = off + w
        end
    end
    return true
end

function Net._frame(kind, payload)
    payload = payload or ""
    return kind .. #payload .. ":" .. payload
end

local function childMain(spec, fd)
    local function emit(kind, payload) return writeAll(fd, Net._frame(kind, payload)) end
    local ok, err = pcall(Net._perform, spec, emit)
    if not ok then emit("E", "internal: " .. tostring(err)) end
    C.close(fd)
end

-- Parent side --------------------------------------------------------------------------------------------------

-- Frames arrive split anywhere; feed(data, on_frame) calls on_frame(kind, payload) for each complete one.
function Net._decoder()
    local buf, pos = "", 1
    return function(data, on_frame)
        if data and data ~= "" then
            buf = buf:sub(pos) .. data
            pos = 1
        end
        while true do
            local kind, len, start = buf:match("^(%u)(%d+):()", pos)
            if not kind then break end
            len = tonumber(len)
            if #buf - start + 1 < len then break end
            pos = start + len
            on_frame(kind, buf:sub(start, start + len - 1))
        end
    end
end

function Net.classify(raw)
    local s = tostring(raw or ""):lower()
    if s:find("timeout", 1, true) or s:find("timed out", 1, true) then return "timeout", "Took too long" end
    if s:find("tls", 1, true) or s:find("certificate", 1, true) or s:find("handshake", 1, true)
            or s:find("ssl", 1, true) then
        return "tls", "Secure connection failed"
    end
    for _, w in ipairs({ "not known", "name resolution", "unreachable", "refused", "no route", "network is down",
                         "host not found", "nodename" }) do
        if s:find(w, 1, true) then return "offline", "Couldn't connect" end
    end
    if s:find("closed", 1, true) or s:find("broken pipe", 1, true) or s:find("reset", 1, true) then
        return "closed", "The connection dropped"
    end
    return "other", "Network error"
end

local readbuf
local READ_MAX = 64 * 1024

local function readUpTo(fd, n)
    readbuf = readbuf or ffi.new("char[?]", READ_MAX)
    local parts = {}
    while n > 0 do
        local r = tonumber(C.read(fd, readbuf, math.min(n, READ_MAX)))
        if r <= 0 then break end
        parts[#parts + 1] = ffi.string(readbuf, r)
        n = n - r
    end
    return table.concat(parts)
end

-- Only once the child has exited: its end of the pipe is closed, so this ends at EOF without blocking.
local function readToEnd(fd)
    readbuf = readbuf or ffi.new("char[?]", READ_MAX)
    local parts = {}
    while true do
        local r = tonumber(C.read(fd, readbuf, READ_MAX))
        if r <= 0 then break end
        parts[#parts + 1] = ffi.string(readbuf, r)
    end
    return table.concat(parts)
end

local function collect(pid, tries)
    if ffiutil.isSubProcessDone(pid) then return end
    if tries >= 90 then -- 30 s at 1 s, then every 10 s: about 10 minutes
        logger.warn("quiet net: child", pid, "not collected")
        return
    end
    UIManager:scheduleIn(tries < 30 and 1 or 10, function() collect(pid, tries + 1) end)
end

-- The child becomes its own process group in KOReader's runInSubProcess (setpgid(0, 0)), but only once it runs:
-- a cancel that comes first would kill(-pid) a group that doesn't exist yet, and the child would go on to make its
-- (paid) request. So the parent makes it a group too, right after the fork (POSIX: both sides may; either wins).
function Net._ownGroup(pid)
    pcall(function() C.setpgid(pid, pid) end)
end

-- Kill a child that hasn't been collected yet: its group and the child itself. A collected child's pid may belong
-- to someone else by now, so it's left alone. Returns true when the child was already collected.
function Net._killChild(pid)
    if ffiutil.isSubProcessDone(pid) then return true end
    C.kill(-pid, 9)
    C.kill(pid, 9)
    return false
end

local active = {}

local Request = {}
Request.__index = Request

function Request:closeFd()
    if self.fd then
        C.close(self.fd)
        self.fd = nil
    end
end

-- Stop polling and make sure the child goes away (killed if it's still running) and gets collected.
function Request:release(kill)
    self.done = true
    active[self] = nil
    if self.poll_fn then UIManager:unschedule(self.poll_fn) end
    if self.pid and not self.reaped then
        if kill and Net._killChild(self.pid) then
            self.reaped = true
        elseif ffiutil.isSubProcessDone(self.pid) then
            self.reaped = true
        else
            collect(self.pid, 0)
        end
    end
    self:closeFd()
end

function Request:info()
    return { ms = time.to_ms(time.since(self.t0)), first_byte_ms = self.first_byte_ms }
end

function Request:fail(raw)
    if self.done then return end
    self:release(true)
    local kind, message = Net.classify(raw)
    local info = self:info()
    info.kind, info.detail = kind, tostring(raw)
    logger.dbg("quiet net:", self.spec.label or "request", "failed:", kind, raw)
    if self.spec.on_error then
        local ok, err = pcall(self.spec.on_error, message, info)
        if not ok then logger.warn("quiet net: on_error failed", err) end
    end
end

function Request:onFrame(kind, payload)
    if self.done then return end
    local spec = self.spec
    if kind == "D" then
        if spec.stream then
            if self.head_len < HEAD_MAX then
                self.head[#self.head + 1] = payload
                self.head_len = self.head_len + #payload
            end
            if spec.on_chunk then
                local ok, err = pcall(spec.on_chunk, payload)
                if not ok then logger.warn("quiet net: on_chunk failed", err) end
            end
        else
            self.head[#self.head + 1] = payload
        end
    elseif kind == "Z" then
        local code, retry = payload:match("^(%d+)\n(.*)$")
        self:release(false)
        local info = self:info()
        info.retry_after = tonumber(retry)
        logger.dbg("quiet net:", spec.label or "request", "HTTP", code, "in", info.ms, "ms")
        if spec.on_done then
            local ok, err = pcall(spec.on_done, tonumber(code) or 0, table.concat(self.head), info)
            if not ok then logger.warn("quiet net: on_done failed", err) end
        end
    elseif kind == "E" then
        self:fail(payload)
    end
end

function Request:poll()
    if self.done then return end
    local n = ffiutil.getNonBlockingReadSize(self.fd) or 0
    local got = false
    if n > 0 then
        local data = readUpTo(self.fd, n)
        if data ~= "" then
            got = true
            self.last = time.now()
            self.first_byte_ms = self.first_byte_ms or time.to_ms(time.since(self.t0))
            self.feed(data, self.on_frame)
        end
    elseif ffiutil.isSubProcessDone(self.pid) then
        self.reaped = true
        local rest = readToEnd(self.fd)
        if rest ~= "" then self.feed(rest, self.on_frame) end
        if not self.done then self:fail("closed: child exited") end
        return
    end
    if self.done then return end
    if time.to_s(time.since(self.last)) > self.idle_timeout then
        return self:fail("timeout: nothing for " .. self.idle_timeout .. " s")
    end
    if time.to_s(time.since(self.t0)) > self.total_timeout then
        return self:fail("timeout: over " .. self.total_timeout .. " s")
    end
    self.interval = got and POLL_ACTIVE or math.min(self.interval * 1.5, POLL_IDLE_MAX)
    UIManager:scheduleIn(self.interval, self.poll_fn)
end

-- Drop the request. No callback runs afterwards.
function Request:cancel()
    if self.done then return end
    logger.dbg("quiet net:", self.spec.label or "request", "cancelled")
    self:release(true)
end

function Net.request(spec)
    local req = setmetatable({
        spec = spec, t0 = time.now(), interval = POLL_FIRST,
        idle_timeout = spec.timeout or 60, total_timeout = spec.total_timeout or 300,
        head = {}, head_len = 0, feed = Net._decoder(),
    }, Request)
    req.last = req.t0
    req.on_frame = function(kind, payload) req:onFrame(kind, payload) end
    req.poll_fn = function() req:poll() end
    spec.block_timeout = req.idle_timeout + 5
    local pid, fd = ffiutil.runInSubProcess(function(_, write_fd) childMain(spec, write_fd) end, true)
    if not pid then
        UIManager:nextTick(function() req:fail("other: " .. tostring(fd)) end)
        return req
    end
    Net._ownGroup(pid)
    req.pid, req.fd = pid, fd
    active[req] = true
    UIManager:scheduleIn(req.interval, req.poll_fn)
    return req
end

function Net.cancelAll()
    for req in pairs(active) do req:cancel() end
end

-- Wi-Fi up with an address (no DNS lookup, so it never blocks).
function Net.isOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok then return true end
    local ok2, up = pcall(function() return NetworkMgr:isWifiOn() and NetworkMgr:isConnected() end)
    return ok2 and up and true or false
end

-- Wi-Fi on without freezing the page or putting anything on screen. On a Kindle, NetworkMgr's own bring-up
-- (enableWifi, turnOnWifiAndWaitForConnection) scans for networks synchronously: kindleScanThenGetResults polls
-- with usleep for up to 20 s while nothing else runs, and shows "Scanning…"/"Connecting…" boxes. Instead the
-- radio is switched on the Kindle's own way (the lipc calls of Amazon's airplane-mode switch, as KOReader's
-- kindleEnableWifi makes them), which returns at once; Amazon's wifid then joins its known network by itself, and
-- whenOnline's own check sees it (on a Kindle isWifiOn/isConnected read sysfs and the interface address live).
-- No NetworkMgr connectivity check is started: those can't be cancelled one by one, and a stale one turns Wi-Fi
-- off when its 45 s run out, even under a newer request (review C4-R3-1). Returns "quiet" for that path;
-- elsewhere enableWifi, not interactive (its own result).
function Net._wifiOn(go)
    local NetworkMgr = require("ui/network/manager")
    local Device = require("device")
    if Device:isKindle() then
        local haslipc, lipc = pcall(require, "liblipclua")
        local h = haslipc and lipc and lipc.init("com.github.koreader.quietnet")
        if h then
            local ok = pcall(function()
                h:set_int_property("com.lab126.cmd", "wirelessEnable", 1)
                h:set_int_property("com.lab126.wifid", "enable", 1)
            end)
            h:close()
            if ok then return "quiet" end
        end
    end
    return NetworkMgr:enableWifi(go, false)
end

-- What NetworkMgr's connectivity check does when the network comes up, for a connection it didn't make itself:
-- its cached state, the lease's network (else it later takes the lease for stale and re-DHCPs), "Wi-Fi was on",
-- and the NetworkConnected event other modules wait for. Skipped while NetworkMgr's own check is running (it
-- does all this itself).
function Net._adoptConnection()
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr.pending_connectivity_check then return end
    pcall(function()
        NetworkMgr:queryNetworkState()
        NetworkMgr.wifi_was_on = true
        G_reader_settings:makeTrue("wifi_was_on")
        local nw = NetworkMgr:getCurrentNetwork()
        if nw and nw.ssid then NetworkMgr.lease_ssid = nw.ssid end
        UIManager:broadcastEvent(require("ui/event"):new("NetworkConnected"))
    end)
end

-- Run fn once connected. Wi-Fi is switched on without asking first (the reader just asked for something that
-- needs it) and without any box (Net._wifiOn). on_fail("No Wi-Fi") when that doesn't work out within ~50 s.
-- Returns a handle: handle:cancel() stops waiting, and neither fn nor on_fail runs afterwards.
function Net.whenOnline(fn, on_fail)
    local handle = { settled = false }
    function handle.cancel() handle.settled = true end
    if Net.isOnline() then
        handle.settled = true
        fn()
        return handle
    end
    local t0 = time.now()
    local check
    local function settle()
        handle.settled = true
        if check then UIManager:unschedule(check) end
    end
    function handle.cancel() settle() end
    local quiet = false
    local function go()
        if handle.settled then return end
        settle()
        if quiet then Net._adoptConnection() end
        fn()
    end
    local function give_up()
        if handle.settled then return end
        settle()
        if on_fail then on_fail("No Wi-Fi") end
    end
    local ok, ret = pcall(Net._wifiOn, go)
    if not ok or ret == false then
        logger.warn("quiet net: Wi-Fi didn't come on", ok and "" or ret)
        give_up()
        return handle
    end
    quiet = ret == "quiet"
    check = function()
        if handle.settled then return end
        if Net.isOnline() then return go() end
        if time.to_s(time.since(t0)) > 50 then return give_up() end
        UIManager:scheduleIn(1, check)
    end
    UIManager:scheduleIn(1, check)
    return handle
end

return Net
