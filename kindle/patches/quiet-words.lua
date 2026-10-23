--[[
quiet-words.lua WORDS.gz CACHE: the Quiet keyboard's suggestions and corrections, in a process of its own.

Not a patch (no number in its name: KOReader never runs it). 2-quiet-keyboard.lua starts it with KOReader's luajit and
talks to it over two pipes; the work is quiet-decoder.lua's (see there). Apart from KOReader so that a search never
holds the reader up, and so that its memory is its own: the word list is mapped from CACHE (built from WORDS.gz the
first time, then this process starts itself again so that only the mapping stays), ~3 MB of its own after that.

Starts niced (a first start builds the cache: ~2 s of work KOReader's pages shouldn't wait for), back to KOReader's
own priority once the words are in, and says so: "R\tWORDS\n". Only then is a slow answer a stuck helper.

Lines in:
  K\tKEY_W\tKEY_H\ta:X,Y;b:X,Y;...        the letter keys' centres (once, and again if the keyboard changes)
  ID\tFLAGS\tWORD\tX,Y;X,Y;...             a word as tapped (k in FLAGS: one of the user's own words; "-" for a tap
                                         with no position)
Lines out:
  ID\tFIX\tVALID\tCOST\tWORD:COST[+]\t...    the correction a space would make (or nothing), whether the word as
                                         typed is a word, what keeping it costs, then the likeliest words (+ for a
                                         completion), best first
When several words are waiting, only the newest is answered: the others were for letters already typed past.
]]

local ffi = require("ffi")
ffi.cdef[[
struct q_words_pollfd { int fd; short events; short revents; };
int poll(struct q_words_pollfd *fds, unsigned long n, int timeout);
long read(int fd, void *buf, unsigned long n);
int execl(const char *path, const char *arg, ...);
int setpriority(int which, int who, int prio);
]]

local words_path, cache_path = arg[1], arg[2]
local here = (arg[0]:match("^(.*)/") or ".") .. "/"
local Decoder = dofile(here .. "quiet-decoder.lua")

ffi.C.setpriority(0, 0, 10) -- PRIO_PROCESS, this process: nice 10 while loading
local dec, saved = Decoder.cached(words_path, cache_path)
if not dec then os.exit(1) end
if saved then
    -- start again, mapping the cache just written: the building's memory goes with this process (when the cache
    -- couldn't be written, this one goes on with what it built)
    local luajit = arg[-1] or "luajit"
    ffi.C.execl(luajit, luajit, arg[0], words_path, cache_path, nil)
end
ffi.C.setpriority(0, 0, 0) -- answering keys: KOReader's own priority again
io.stdout:write("R\t", dec.nwords, "\n")
if not io.stdout:flush() then os.exit(0) end

local MAX_WORDS = 6

local function answer(id, flags, word, taps_s)
    local taps, i = {}, 0
    for ch in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        i = i + 1
        taps[i] = { ch = ch }
    end
    local k = 0
    for xy in (taps_s or ""):gmatch("[^;]+") do
        k = k + 1
        local x, y = xy:match("^(-?[%d.]+),(-?[%d.]+)$")
        if taps[k] and x then taps[k].x, taps[k].y = tonumber(x), tonumber(y) end
    end
    local ok, r = pcall(dec.decode, dec, taps, { known = flags:find("k") ~= nil })
    local out = { id, "", "0", "0" }
    if ok and r then
        out[2] = r.fix or ""
        out[3] = r.valid and "1" or "0"
        out[4] = string.format("%.2f", r.lit_cost or 0)
        for j = 1, math.min(#r.cands, MAX_WORDS) do
            local c = r.cands[j]
            out[#out + 1] = string.format("%s:%.2f%s", c.word:gsub("[\t\n:]", " "), c.cost, c.completion and "+" or "")
        end
    end
    local wrote = io.stdout:write(table.concat(out, "\t"), "\n")
    if not wrote or not io.stdout:flush() then os.exit(0) end -- KOReader has gone
end

local function handle(line)
    if line:sub(1, 2) == "K\t" then
        local kw, kh, list = line:match("^K\t([%d.]+)\t([%d.]+)\t(.*)$")
        if kw then
            local centres = {}
            for ch, x, y in list:gmatch("(%a):(-?[%d.]+),(-?[%d.]+)") do centres[ch] = { tonumber(x), tonumber(y) } end
            dec:setKeys(centres, tonumber(kw), tonumber(kh))
        end
        return
    end
    if not dec.kx then return end -- no keys yet
    local id, flags, word, taps = line:match("^(%d+)\t([^\t]*)\t([^\t]+)\t?(.*)$")
    if id then answer(id, flags, word, taps) end
end

local chunk = ffi.new("char[4096]")
local pfd = ffi.new("struct q_words_pollfd[1]")
pfd[0].fd, pfd[0].events = 0, 1 -- stdin, POLLIN
local buf = ""

local function readMore()
    local n = tonumber(ffi.C.read(0, chunk, 4096))
    if not n or n <= 0 then os.exit(0) end
    buf = buf .. ffi.string(chunk, n)
end

while true do
    readMore() -- waits for a request
    while ffi.C.poll(pfd, 1, 0) > 0 do readMore() end -- and takes in whatever else is already waiting
    local last
    for line in buf:gmatch("([^\n]*)\n") do
        if line:sub(1, 2) == "K\t" then handle(line) else last = line end -- keys always, words: the newest
    end
    buf = buf:match("[^\n]*$")
    if last then handle(last) end
end
