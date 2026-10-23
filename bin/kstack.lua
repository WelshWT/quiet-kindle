--[[
kstack.lua PID: where KOReader (LuaJIT 2.1, 32-bit) is, as a Lua traceback, read from /proc/PID/mem. Run on the
Kindle with KOReader's luajit (bin/kstack does). Reads only.

The main thread's C stack is searched for a lua_State (one is always there below a running Lua call: the cframe keeps
it, and a C function called from Lua has it too); its frames are walked as LuaJIT's lj_debug_frame does. Most useful
when KOReader is inside a C call (a lipc get, a read): L->base is current then. Code addresses found on the C stack are
listed first, for a freeze inside a C library.
]]
local ffi = require("ffi")
ffi.cdef[[
int open(const char *path, int flags);
long pread64(int fd, void *buf, unsigned long n, int64_t off);
int usleep(unsigned int usec);
]]

local pid = assert(tonumber(arg[1]), "usage: kstack.lua PID")
local fd = ffi.C.open("/proc/" .. pid .. "/mem", 0)
assert(fd >= 0, "can't read /proc/" .. pid .. "/mem")
local buf = ffi.new("uint8_t[?]", 65536)
local function rd(addr, n)
    if not addr or addr == 0 or n > 65536 then return nil end
    if ffi.C.pread64(fd, buf, n, addr) ~= n then return nil end
    return ffi.string(buf, n)
end
local function u32(addr)
    local s = rd(addr, 4)
    if not s then return nil end
    local a, b, c, d = s:byte(1, 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function u16(addr)
    local s = rd(addr, 2)
    if not s then return nil end
    local a, b = s:byte(1, 2)
    return a + b * 256
end
local function u8(addr)
    local s = rd(addr, 1)
    return s and s:byte()
end

local maps = {}
for line in io.lines("/proc/" .. pid .. "/maps") do
    local a, b, perm, off, path = line:match("^(%x+)-(%x+) (%S+) (%x+) %S+ %S+%s*(.*)$")
    if a then maps[#maps + 1] = { tonumber(a, 16), tonumber(b, 16), perm, tonumber(off, 16), path } end
end
local function mapOf(addr)
    for _, m in ipairs(maps) do
        if addr >= m[1] and addr < m[2] then return m end
    end
end
local function where(addr)
    local m = mapOf(addr)
    if not m then return string.format("0x%x", addr) end
    return string.format("%s+0x%x", m[5] ~= "" and m[5]:match("[^/]*$") or "anon", addr - m[1] + m[4])
end

-- GCstr: the text follows the header (20 bytes in current LuaJIT 2.1, 16 in older ones)
local function gcstr(s)
    if not s or u8(s + 5) ~= 4 then return nil end
    for _, lay in ipairs({ { 16, 20 }, { 12, 16 } }) do
        local len = u32(s + lay[1])
        if len and len > 0 and len < 4096 then
            local d = rd(s + lay[2], len)
            if d and d:match("^[%g ]+$") then return d end
        end
    end
end

local PROTO = 64 -- sizeof(GCproto), 32-bit: the bytecode follows it
-- the source line of the instruction before ins (a return address into the function's bytecode)
local function lineOf(pt, bc, ins)
    local pos = (ins - bc) / 4 - 1
    local sizebc, first, numline, li = u32(pt + 8), u32(pt + 44), u32(pt + 48), u32(pt + 52)
    if not (sizebc and li and li ~= 0) or pos < 0 or pos > sizebc then return -1 end
    if pos == sizebc then return first + numline end
    if pos == 0 then return first end
    pos = pos - 1
    if numline < 256 then return first + u8(li + pos) end
    if numline < 65536 then return first + u16(li + 2 * pos) end
    return first + u32(li + 4 * pos)
end

local function describe(fn, ins)
    local ffid = u8(fn + 6)
    if ffid == 0 then
        local bc = u32(fn + 16)
        local pt = bc and bc - PROTO
        if not pt or u8(pt + 5) ~= 7 then return string.format("Lua function 0x%x", fn) end
        local line = ins and lineOf(pt, bc, ins) or -1
        return string.format("%s:%d (in the function at line %d)", gcstr(u32(pt + 40)) or "?", line, u32(pt + 44))
    elseif ffid == 1 then
        local f = u32(fn + 20)
        return "C function " .. (f and where(f) or "?")
    end
    return "builtin #" .. tostring(ffid)
end

local function walk(L)
    local frame, bot = u32(L + 16) - 8, u32(L + 28)
    local ins -- the return address into the frame being described, from the frame above it
    for n = 0, 99 do
        if frame <= bot then return end
        local fn, link = u32(frame), u32(frame + 4)
        if not fn or not link then
            print("  (unreadable frame)")
            return
        end
        print(string.format("  #%-2d %s", n, describe(fn, ins)))
        if link % 4 == 0 then -- a Lua frame: the link is the return address into the caller
            ins = link
            local call = u32(link - 4)
            if not call then return end
            frame = frame - 8 * (1 + math.floor(call / 256) % 256)
        else
            ins = (link % 8 == 2) and u32(frame - 4) or nil -- a continuation keeps its return address below
            if link % 4 == 1 then print("  (C)") end
            if link % 8 >= 6 then print("  (pcall)") end
            frame = frame - (link - link % 8)
        end
    end
end

-- the main thread's stack pointer: from its system call, or where it was stopped (not while it is running)
local fields
for _ = 1, 200 do
    local f = io.open("/proc/" .. pid .. "/task/" .. pid .. "/syscall")
    local sc = f and f:read("*l")
    if f then f:close() end
    if sc and sc ~= "running" then
        fields = {}
        for w in sc:gmatch("%S+") do fields[#fields + 1] = w end
        break
    end
    ffi.C.usleep(10000)
end
assert(fields, "the main thread never stopped running for a look")
local sp, pc
if fields[1] == "-1" then
    sp, pc = tonumber(fields[2]), tonumber(fields[3])
    print(string.format("main thread: not in a system call, at %s", where(pc)))
else
    sp, pc = tonumber(fields[8]), tonumber(fields[9])
    print(string.format("main thread: in system call %s, at %s", fields[1], where(pc)))
end

local m = mapOf(sp)
local raw = m and rd(sp, math.min(16384, m[2] - sp))
assert(raw, "can't read the main thread's stack")
local code, states, seen = {}, {}, {}
for i = 0, #raw / 4 - 1 do
    local a, b, c, d = raw:byte(4 * i + 1, 4 * i + 4)
    local w = a + b * 256 + c * 65536 + d * 16777216
    local wm = mapOf(w)
    if wm and wm[3]:sub(3, 3) == "x" and #code < 24 then code[#code + 1] = where(w) end
    if w % 8 == 0 and not seen[w] and u8(w + 5) == 6 then -- a lua_State?
        seen[w] = true
        local base, top, maxstack, stack = u32(w + 16), u32(w + 20), u32(w + 24), u32(w + 28)
        if base and top and maxstack and stack and stack <= base and base <= top and top <= maxstack + 64 then
            states[#states + 1] = w
        end
    end
end
print("code addresses on the C stack, innermost first (rough: old values left in frames show up too):")
for _, c in ipairs(code) do print("  " .. c) end
if #states == 0 then print("no lua_State on the C stack") end
for _, L in ipairs(states) do
    print(string.format("Lua stack of lua_State 0x%x, innermost first:", L))
    walk(L)
end
