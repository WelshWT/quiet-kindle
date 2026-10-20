-- khold.lua X Y [ms [X2 Y2]] — press at (X, Y) on the touchscreen, hold for ms (default 1200), optionally drag to
-- (X2, Y2), let go. Run on the Kindle with KOReader's luajit (bin/khold copies it over). Writes raw multitouch
-- events like a finger would. Every argument is checked before the finger goes down, and the finger is always
-- lifted: on an error during the hold (review C1-11), and on SIGINT/SIGTERM while it holds (review C1-20), and on
-- SIGHUP (the ssh connection dropped) or SIGPIPE — a contact left down confuses later input.
local ffi = require("ffi")
ffi.cdef[[
struct q_timeval { long tv_sec; long tv_usec; };
struct q_input_event { struct q_timeval time; unsigned short type; unsigned short code; int value; };
int open(const char *path, int flags);
int write(int fd, const void *buf, unsigned int count);
int close(int fd);
int usleep(unsigned int usec);
typedef void (*q_sighandler)(int);
q_sighandler signal(int signum, q_sighandler handler);
void _exit(int status);
]]
local function int(v) local n = tonumber(v) return n and n >= 0 and n == math.floor(n) and n or nil end
local x, y = int(arg[1]), int(arg[2])
local ms = arg[3] == nil and 1200 or int(arg[3])
local x2, y2 = int(arg[4]), int(arg[5])
local usage = "usage: khold.lua X Y [ms [X2 Y2]] (whole numbers, 0 or more)"
assert(x and y and ms, usage)
assert((arg[4] == nil and arg[5] == nil) or (x2 and y2), usage)
local fd = ffi.C.open("/dev/input/event1", 1) -- O_WRONLY
assert(fd >= 0, "cannot open the touchscreen")
local EV_SYN, EV_ABS = 0, 3
local ABS_MT_TRACKING_ID, ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 57, 53, 54

-- The release (lift the finger), pre-built in C so a signal can send it without touching Lua: tracking id -1, SYN.
local SZ = ffi.sizeof("struct q_input_event")
local release = ffi.new("struct q_input_event[2]")
release[0].type, release[0].code, release[0].value = EV_ABS, ABS_MT_TRACKING_ID, -1
release[1].type, release[1].code, release[1].value = EV_SYN, 0, 0
local function lift() ffi.C.write(fd, release, 2 * SZ) end

-- A signal that would end the process: lift the finger, then exit. Only async-signal-safe C calls; no Lua allocation.
local onsignal = ffi.cast("q_sighandler", function()
    ffi.C.write(fd, release, 2 * SZ)
    ffi.C._exit(0)
end)
ffi.C.signal(1, onsignal)  -- SIGHUP
ffi.C.signal(2, onsignal)  -- SIGINT
ffi.C.signal(13, onsignal) -- SIGPIPE
ffi.C.signal(15, onsignal) -- SIGTERM

local ev = ffi.new("struct q_input_event")
local function emit(t, c, v)
    ev.type, ev.code, ev.value = t, c, v
    ffi.C.write(fd, ev, SZ)
end
local ok, err = pcall(function()
    emit(EV_ABS, ABS_MT_TRACKING_ID, math.random(100, 30000))
    emit(EV_ABS, ABS_MT_POSITION_X, x)
    emit(EV_ABS, ABS_MT_POSITION_Y, y)
    emit(EV_SYN, 0, 0)
    ffi.C.usleep(ms * 1000)
    if x2 and y2 then
        for i = 1, 12 do
            emit(EV_ABS, ABS_MT_POSITION_X, math.floor(x + (x2 - x) * i / 12))
            emit(EV_ABS, ABS_MT_POSITION_Y, math.floor(y + (y2 - y) * i / 12))
            emit(EV_SYN, 0, 0)
            ffi.C.usleep(40000)
        end
        ffi.C.usleep(300000)
    end
end)
lift()
ffi.C.close(fd)
assert(ok, err)
