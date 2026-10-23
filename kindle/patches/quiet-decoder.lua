--[[
quiet-decoder.lua: what the Quiet keyboard's taps most likely meant, for its suggestions and corrections.

Not a patch (no number in its name: KOReader never runs it). The keyboard's helper process (quiet-words.lua) loads it;
so does tools/keyboard-eval/eval.lua, which measures it on simulated typing. Plain LuaJIT, no KOReader modules.

The method is the one Google describes for Gboard (Ouyang, Rybach, Beaufays, Riley: "Mobile Keyboard Input Decoding
with Finite-State Transducers", 2017), small enough for a Kindle: each word is scored by how well the taps fit it and
by how common it is, and kept as typed unless something else is clearly likelier.
  - where the finger landed, not just the key: each tap counts against each letter by its distance from the key's
    centre (a Gaussian around every key: a tap between g and h fits both, one on h's far side only h)
  - letters left out, taps too many, two letters swapped, each at a cost; a doubled letter typed once ("realy"), a
    key hit twice and a left-out apostrophe ("dont") cost little
  - how common the word is: the frequency in AOSP's keyboard word list (0-255, a log scale)
  - the word as typed is scored too: as a word when it is one (and correcting away from a real word costs extra,
    as in the paper: "you're far" mustn't become "you're fat"), or else as an unknown word, at a cost per letter,
    lower when it starts with a capital (names); a correction must beat it by a margin
  - words the list never corrects away from: the keyboard's own (put back after a correction, the book's) come in
    as known
All costs are in nats (-log probability). Search: the word list as a trie, walked depth first with one row of
alignment costs per letter (all prefixes share theirs), pruned as soon as a prefix can't beat the best found.

  local Decoder = dofile("quiet-decoder.lua")
  local d = Decoder.load("en.words.gz")              -- ~1.5 s on a Kindle
  d:setKeys({ a = { x, y }, ... }, key_w, key_h)      -- the letter keys' centres, in any one coordinate system
  local r = d:decode({ { ch = "t", x = 573, y = 73 }, ... }, { known = false })
  -- r.literal, r.valid, r.fix (a word or nil), r.cands = { { word, cost, completion }, ... } best first
]]

local ffi = require("ffi")

local Decoder = {}
Decoder.__index = Decoder

Decoder.PARAMS = {
    sigma = 0.36,       -- the spread of taps around a key's centre, in key widths (heights)
    sub_cap = 9.0,      -- a tap never costs more than this against any letter
    ins = 4.5,          -- a tap that belongs to no letter
    ins_dbl = 1.6,      -- ... when it repeats the key before it
    omit = 4.0,         -- a letter with no tap
    omit_dbl = 1.0,     -- ... when it doubles the letter before it ("realy")
    omit_apos = 0.3,    -- ... when it is an apostrophe ("dont")
    swap = 2.6,         -- two taps in the wrong order
    comp = 1.1,         -- each letter a completion adds
    lm = 16.0,          -- frequency 0 costs this much more than 255
    oov = 7.0,          -- keeping an unknown word as typed: this
    oov_per = 1.6,      -- ... plus this per letter (a character model's cost, roughly)
    oov_cap_per = 0.6,  -- ... or this per letter when it starts with a capital: a name, most likely
    valid_extra = 4.0,  -- correcting away from a real word costs this much more
    margin = 0.5,       -- a correction must win by this much
    near = 6.0,         -- a tap costing less than this against a letter is on its key or a neighbour (a far one isn't)
    edge = 6.0,         -- a tap too many, or a letter left out, at the very start of a word (rare: names stay)
    keep = 12,          -- candidates returned
    beam_width = 64,    -- states kept after each tap
    beam = 7.0,         -- ... within this much of the best
}

local APOS = 26 -- letters are 0-25, the apostrophe 26
local INF = 1e9
local NSYM = 27

local function code(ch)
    if ch == "'" then return APOS end
    local b = ch:byte()
    if b and b >= 97 and b <= 122 then return b - 97 end
    if b and b >= 65 and b <= 90 then return b - 65 end
    return nil
end

---------------------------------------------------------------------------------------------------- loading

-- The word list (tools/keyboard-words/make_words.py): "key\tf\tflags[\tword]" sorted by key, then "=key\tword"
-- corrections. Built into a trie in flat arrays (two passes over the text: the first counts, so every array is
-- allocated once at its size): chr, child, sib, parent, wordat (first word ending here), below (likeliest offerable
-- word under a node); per word: freq, offensive, nextw (next word with the same key), wnode (its node), and the
-- spelling only where it isn't the key (capitals, accents).
function Decoder.load(path, opts)
    opts = opts or {}
    local p = io.popen("gzip -dc '" .. path:gsub("'", "") .. "' 2>/dev/null")
    if not p then return nil, "can't read " .. path end
    local all = p:read("*a")
    p:close()
    local self = setmetatable({ p = {} }, Decoder)
    for k, v in pairs(Decoder.PARAMS) do self.p[k] = v end
    for k, v in pairs(opts.params or {}) do self.p[k] = v end
    local max_words = opts.max_words or math.huge

    -- pass 1: words, and nodes (one per letter not shared with the key before)
    local W, N, prev = 0, 1, ""
    for k in all:gmatch("([^\t\n=][^\t\n]*)\t%d+\t[^\t\n]*[^\n]*\n") do
        if W >= max_words then break end
        W = W + 1
        local common, m = 0, math.min(#k, #prev)
        while common < m and k:byte(common + 1) == prev:byte(common + 1) do common = common + 1 end
        N = N + #k - common
        prev = k
    end
    if W == 0 then return nil, "no words in " .. path end
    local chr = ffi.new("uint8_t[?]", N + 1)
    local child = ffi.new("int32_t[?]", N + 1)
    local sib = ffi.new("int32_t[?]", N + 1)
    local parent = ffi.new("int32_t[?]", N + 1)
    local wordat = ffi.new("int32_t[?]", N + 1)
    local lastc = ffi.new("int32_t[?]", N + 1) -- only while building
    local freq = ffi.new("uint8_t[?]", W + 1)
    local offensive = ffi.new("uint8_t[?]", W + 1)
    local nextw = ffi.new("int32_t[?]", W + 1)
    local wnode = ffi.new("int32_t[?]", W + 1)
    local wlen = ffi.new("uint8_t[?]", W + 1)
    local spelt, shortcuts = {}, {}

    -- pass 2: the trie
    local nodes, w, stack = 1, 0, { 1 } -- stack[d + 1]: node of the previous key's first d letters
    prev = ""
    for line in all:gmatch("([^\n]*)\n") do
        if line:byte(1) == 61 then -- "="
            local k, sw = line:match("^=([^\t]+)\t(.+)$")
            if k then shortcuts[k] = sw end
        elseif w < W then
            local k, f, fl, sp = line:match("^([^\t]+)\t(%d+)\t([^\t]*)\t?(.*)$")
            if k then
                w = w + 1
                freq[w], offensive[w], wlen[w] = tonumber(f), fl:find("o") and 1 or 0, math.min(#k, 255)
                if sp ~= "" and sp ~= k then spelt[w] = sp end
                local common, m = 0, math.min(#k, #prev)
                while common < m and k:byte(common + 1) == prev:byte(common + 1) do common = common + 1 end
                local node = stack[common + 1]
                for d = common + 1, #k do
                    nodes = nodes + 1
                    local nn = nodes
                    chr[nn], parent[nn] = code(k:sub(d, d)), node
                    if child[node] == 0 then child[node] = nn else sib[lastc[node]] = nn end
                    lastc[node] = nn
                    node = nn
                    stack[d + 1] = nn
                end
                for d = #k + 2, #stack do stack[d] = nil end
                wnode[w] = node
                -- words with the same key chain at one node, likeliest first (the list is sorted that way)
                if wordat[node] == 0 then
                    wordat[node] = w
                else
                    local x = wordat[node]
                    while nextw[x] ~= 0 do x = nextw[x] end
                    nextw[x] = w
                end
                prev = k
            end
        end
    end
    all, lastc = nil, nil

    -- the likeliest offerable word strictly below each node, for completions (children come after parents)
    local below = ffi.new("int32_t[?]", nodes + 1)
    local function better(a, b)
        if a == 0 then return b end
        if b == 0 then return a end
        return freq[b] > freq[a] and b or a
    end
    for n = nodes, 2, -1 do
        local own, x = 0, wordat[n]
        while x ~= 0 do
            if offensive[x] == 0 then own = better(own, x) end
            x = nextw[x]
        end
        local par = parent[n]
        below[par] = better(below[par], better(own, below[n]))
    end
    self.nwords, self.nodes = W, nodes
    self.chr, self.child, self.sib, self.parent, self.wordat, self.below = chr, child, sib, parent, wordat, below
    self.freq, self.offensive, self.nextw, self.wnode, self.wlen = freq, offensive, nextw, wnode, wlen
    self.spelt, self.shortcuts = spelt, shortcuts
    collectgarbage()
    return self
end

---------------------------------------------------------------------------------------------------- the cache

-- The built trie, saved as one file and mapped back read-only (as AOSP's keyboard maps its dictionaries): the next
-- start takes milliseconds, and the kernel loads only the pages a search touches (and can drop them again), so the
-- process keeps ~3 MB of its own instead of ~15. Little-endian arrays, each 4-byte aligned, after a header that
-- names the word list it came from (path, size, modification time): a different list makes a new cache.
ffi.cdef[[
void *mmap(void *addr, size_t length, int prot, int flags, int fd, long offset);
int open(const char *path, int flags);
int close(int fd);
]]

local MAGIC = "QKW2"

local function signature(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    local mtime = ""
    local p = io.popen("stat -c %Y '" .. path:gsub("'", "") .. "' 2>/dev/null")
    if p then mtime = p:read("*l") or ""; p:close() end
    return path .. "|" .. size .. "|" .. mtime
end

-- the arrays, in file order: name, element type, count field
local LAYOUT = {
    { "chr", "uint8_t", "N" }, { "child", "int32_t", "N" }, { "sib", "int32_t", "N" },
    { "parent", "int32_t", "N" }, { "wordat", "int32_t", "N" }, { "below", "int32_t", "N" },
    { "freq", "uint8_t", "W" }, { "offensive", "uint8_t", "W" }, { "wlen", "uint8_t", "W" },
    { "nextw", "int32_t", "W" }, { "wnode", "int32_t", "W" }, { "spelt_at", "int32_t", "W" },
}

local function align4(n) return n + (4 - n % 4) % 4 end

function Decoder:save(path, sig)
    local tmp = path .. ".part"
    local f = io.open(tmp, "wb")
    if not f then return false end
    local N, W = self.nodes, self.nwords
    -- the spellings: one block of NUL-terminated strings, found by offset (0 = none)
    local blob, spelt_at, at = { "\0" }, ffi.new("int32_t[?]", W + 1), 1
    for w = 1, W do
        local s = self.spelt[w]
        if s then
            spelt_at[w] = at
            blob[#blob + 1] = s .. "\0"
            at = at + #s + 1
        end
    end
    blob = table.concat(blob)
    local sc = {}
    for k, v in pairs(self.shortcuts) do sc[#sc + 1] = k .. "\t" .. v end
    sc = table.concat(sc, "\n")
    local header = table.concat({ MAGIC, sig, N, W, #blob, #sc }, "\n") .. "\n"
    f:write(header, string.rep("\0", align4(#header) - #header))
    local arrays = { spelt_at = spelt_at }
    for _, a in ipairs(LAYOUT) do
        local name, t, count = a[1], a[2], a[3] == "N" and N or W
        local bytes = (count + 1) * ffi.sizeof(t)
        f:write(ffi.string(arrays[name] or self[name], bytes), string.rep("\0", align4(bytes) - bytes))
    end
    f:write(blob, string.rep("\0", align4(#blob) - #blob), sc)
    local ok = f:close()
    return ok and os.rename(tmp, path) or (os.remove(tmp) and false)
end

function Decoder.open(path, sig, opts)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(4096) or ""
    local size = f:seek("end")
    f:close()
    local magic, s, N, W, nblob, nsc = head:match("^(%w+)\n([^\n]*)\n(%d+)\n(%d+)\n(%d+)\n(%d+)\n")
    if magic ~= MAGIC or s ~= sig then return nil end
    N, W, nblob, nsc = tonumber(N), tonumber(W), tonumber(nblob), tonumber(nsc)
    local fd = ffi.C.open(path, 0) -- O_RDONLY
    if fd < 0 then return nil end
    local base = ffi.C.mmap(nil, size, 1, 1, fd, 0) -- PROT_READ, MAP_SHARED
    ffi.C.close(fd)
    if base == nil or ffi.cast("intptr_t", base) == -1 then return nil end
    local self = setmetatable({ p = {} }, Decoder)
    for k, v in pairs(Decoder.PARAMS) do self.p[k] = v end
    for k, v in pairs((opts or {}).params or {}) do self.p[k] = v end
    local headlen = #head:match("^%w+\n[^\n]*\n%d+\n%d+\n%d+\n%d+\n")
    local off = align4(headlen)
    local bytes = ffi.cast("uint8_t *", base)
    for _, a in ipairs(LAYOUT) do
        local name, t, count = a[1], a[2], a[3] == "N" and N or W
        self[name] = ffi.cast(t .. " *", bytes + off)
        off = off + align4((count + 1) * ffi.sizeof(t))
    end
    self.blob = bytes + off
    off = off + align4(nblob)
    if off + nsc > size then return nil end
    self.shortcuts = {}
    for k, v in ffi.string(bytes + off, nsc):gmatch("([^\t\n]+)\t([^\n]+)") do self.shortcuts[k] = v end
    self.nodes, self.nwords, self.map = N, W, base -- the mapping lives as long as the decoder
    return self
end

-- The decoder for a word list: mapped from its cache when there is one for this very list, else built (and the
-- cache written for next time). Returns the decoder and whether a cache was just written (opening that instead
-- would leave the building's memory behind).
function Decoder.cached(words_path, cache_path, opts)
    local sig = signature(words_path)
    if not sig then return nil, "can't read " .. words_path end
    local d = Decoder.open(cache_path, sig, opts)
    if d then return d, false end
    local built, err = Decoder.load(words_path, opts)
    if not built then return nil, err end
    return built, built:save(cache_path, sig) == true
end

-- A word as written: its spelling when it has one of its own, else its key, read back up the trie.
function Decoder:word(w)
    if self.blob then
        local at = self.spelt_at[w]
        if at > 0 then return ffi.string(self.blob + at) end
    else
        local s = self.spelt[w]
        if s then return s end
    end
    local out, node = {}, self.wnode[w]
    while node > 1 do
        local c = self.chr[node]
        out[#out + 1] = c == APOS and "'" or string.char(97 + c)
        node = self.parent[node]
    end
    return string.reverse(table.concat(out))
end

-- The letter keys' centres (any coordinate system the taps use) and a key's size there.
function Decoder:setKeys(centres, key_w, key_h)
    self.kx, self.ky = {}, {}
    for ch, c in pairs(centres) do
        local cc = code(ch)
        if cc and cc ~= APOS then self.kx[cc], self.ky[cc] = c[1], c[2] end
    end
    self.key_w, self.key_h = key_w, key_h
end

---------------------------------------------------------------------------------------------------- decoding

-- The node a key ends at, or nil.
function Decoder:find(key)
    local node = 1
    for i = 1, #key do
        local c = code(key:sub(i, i))
        if not c then return nil end
        local n = self.child[node]
        while n ~= 0 and self.chr[n] ~= c do n = self.sib[n] end
        if n == 0 then return nil end
        node = n
    end
    return node
end

function Decoder:lmCost(w)
    return (255 - self.freq[w]) / 255 * self.p.lm
end

-- A word's key as letter codes, read back up the trie.
function Decoder:codes(w)
    local out, node = {}, self.wnode[w]
    while node > 1 do
        out[#out + 1] = self.chr[node]
        node = self.parent[node]
    end
    local n = #out
    for i = 1, math.floor(n / 2) do out[i], out[n + 1 - i] = out[n + 1 - i], out[i] end
    return out
end

--[[ How many far edits the cheapest way from the taps to a word needs: a tap far from its letter's key, a tap too
many or a letter left out (a key hit twice, a doubled letter typed once and a left-out apostrophe are near; so are
two swapped taps on their keys). The same costs as the search, one word at a time (M, tcode: decode's). ]]
function Decoder:farEdits(M, tcode, n, L)
    local p = self.p
    local m = #L
    local cost, far = {}, {}
    local function at(i, j) return i * (m + 1) + j end
    for i = 0, n do
        for j = 0, m do
            local best, bf = (i == 0 and j == 0) and 0 or INF, 0
            local function try(c, f)
                if c < best or (c == best and f < bf) then best, bf = c, f end
            end
            if i > 0 and j > 0 then -- tap i is letter j
                local s = M[i * NSYM + L[j]]
                try(cost[at(i - 1, j - 1)] + s, far[at(i - 1, j - 1)] + (s < p.near and 0 or 1))
            end
            if i > 0 then -- tap i is too many
                local dbl = j > 0 and i > 1 and tcode[i] == tcode[i - 1]
                try(cost[at(i - 1, j)] + (j == 0 and p.edge or dbl and p.ins_dbl or p.ins), far[at(i - 1, j)] + (dbl and 0 or 1))
            end
            if j > 0 then -- letter j was left out
                local c, last = L[j], L[j - 1]
                local near = c == APOS or (j > 1 and c == last)
                local oc = c == APOS and p.omit_apos or j == 1 and p.edge or c == last and p.omit_dbl or p.omit
                try(cost[at(i, j - 1)] + oc, far[at(i, j - 1)] + (near and 0 or 1))
            end
            if i > 1 and j > 1 then -- taps i - 1 and i swapped
                local s1, s2 = M[(i - 1) * NSYM + L[j]], M[i * NSYM + L[j - 1]]
                try(cost[at(i - 2, j - 2)] + p.swap + s1 + s2, far[at(i - 2, j - 2)] + ((s1 < p.near and s2 < p.near) and 0 or 1))
            end
            cost[at(i, j)], far[at(i, j)] = best, bf
        end
    end
    return far[at(n, m)]
end


--[[ taps: { { ch = "t", x = ..., y = ... }, ... } (x, y may be nil: the key's centre). opts.known: the word as
typed is one of the user's (never corrected). Returns { literal, valid, lit_cost, fix, cands } where cands are the
likeliest words, best first: { word = display, cost = nats, completion = true when longer than the taps }. ]]
function Decoder:decode(taps, opts)
    opts = opts or {}
    local p = self.p
    local n = #taps
    local literal = {}
    for i = 1, n do literal[i] = taps[i].ch end
    literal = table.concat(literal)
    local lkey = literal:lower()
    local result = { literal = literal, cands = {} }
    if n == 0 or n > 30 then return result end

    -- each tap against each letter
    local M = ffi.new("double[?]", (n + 1) * NSYM)
    local sx, sy = p.sigma * self.key_w, p.sigma * self.key_h
    local tcode = {}
    for i = 1, n do
        local t = taps[i]
        local tc = code(t.ch)
        tcode[i] = tc
        local tx, ty = t.x, t.y
        if (not tx or not ty) and tc and tc ~= APOS then tx, ty = self.kx[tc], self.ky[tc] end
        for c = 0, 25 do
            local cost = p.sub_cap
            if tx and self.kx[c] then
                local dx, dy = (tx - self.kx[c]) / sx, (ty - self.ky[c]) / sy
                cost = math.min(0.5 * (dx * dx + dy * dy), p.sub_cap)
            elseif tc == c then
                cost = 0
            end
            M[i * NSYM + c] = cost
        end
        M[i * NSYM + APOS] = (tc == APOS) and 0 or p.sub_cap
        if tc == APOS then
            for c = 0, 25 do M[i * NSYM + c] = p.sub_cap end
        end
    end
    -- what the word as typed costs: its own taps, and then as a word or as unknown
    local lit_spatial = 0
    for i = 1, n do lit_spatial = lit_spatial + (tcode[i] and M[i * NSYM + tcode[i]] or p.sub_cap) end
    local lnode = self:find(lkey)
    local lword = lnode and self.wordat[lnode] or 0
    local valid = lword ~= 0 or opts.known == true
    local lit_cost
    if opts.known then
        lit_cost = -INF -- the user's own words are never corrected
    elseif lword ~= 0 then
        -- a real word as typed: correcting away from it must win by valid_extra more (the paper's "you're far")
        lit_cost = lit_spatial + self:lmCost(lword) - p.valid_extra
    else
        local per = literal:sub(1, 1):match("%u") and p.oov_cap_per or p.oov_per
        lit_cost = lit_spatial + p.oov + per * n
    end
    result.valid, result.lit_cost = valid, lit_cost

    -- Beam search, one tap at a time (as Android's LatinIME does): a state is a prefix of a word in the trie
    -- (a node) with what it has cost to explain the taps so far; each tap moves every state on by a letter it fits,
    -- by a left-out letter and then one it fits, or not at all (a tap too many), or by two letters at once for two
    -- swapped taps. Only the best states go on.
    local chr, child, sib, wordat, below = self.chr, self.child, self.sib, self.wordat, self.below
    local offensive, nextw, wlen = self.offensive, self.nextw, self.wlen
    local beam, spread = p.beam_width, p.beam
    -- states: arrays of node, cost, depth, last letter (for doubled-letter omissions)
    local function newBeam() return { n = 0, node = {}, cost = {}, d = {}, last = {}, at = {} } end
    local function push(b, node, cost, d, last)
        local k = b.at[node]
        if k then
            if cost < b.cost[k] then b.cost[k], b.d[k], b.last[k] = cost, d, last end
            return
        end
        local m = b.n + 1
        b.n = m
        b.node[m], b.cost[m], b.d[m], b.last[m] = node, cost, d, last
        b.at[node] = m
    end
    -- keeps the best `beam` states within `spread` of the best (sorting only those)
    local function prune(b)
        if b.n == 0 then return b end
        local best = INF
        for k = 1, b.n do if b.cost[k] < best then best = b.cost[k] end end
        local idx = {}
        for k = 1, b.n do
            if b.cost[k] <= best + spread then idx[#idx + 1] = k end
        end
        if #idx > beam then table.sort(idx, function(x, y) return b.cost[x] < b.cost[y] end) end
        local out = newBeam()
        for r = 1, math.min(#idx, beam) do
            local k = idx[r]
            push(out, b.node[k], b.cost[k], b.d[k], b.last[k])
        end
        out.best = best
        return out
    end
    local function omitCost(c, last, d)
        if c == APOS then return p.omit_apos end
        if d == 0 then return p.edge end
        if c == last then return p.omit_dbl end
        return p.omit
    end
    local cur = newBeam()
    push(cur, 1, 0, 0, -1)
    cur.best = 0
    local nxt_after = {} -- states that consumed two taps (swaps), keyed by the tap they reach
    for i = 1, n do
        local nb = nxt_after[i] or newBeam()
        nxt_after[i] = nil
        local base = i * NSYM
        -- nothing past this can survive the next prune (the best can only grow by what a tap costs)
        local limit = cur.best + spread + p.sub_cap
        for k = 1, cur.n do
            local node, cost, d, last = cur.node[k], cur.cost[k], cur.d[k], cur.last[k]
            -- this tap is too many
            local ins = (d == 0) and p.edge or ((i > 1 and tcode[i] == tcode[i - 1]) and p.ins_dbl or p.ins)
            if cost + ins < limit then push(nb, node, cost + ins, d, last) end
            local c = child[node]
            while c ~= 0 do
                local ch = chr[c]
                -- this tap is this letter
                local v = cost + M[base + ch]
                if v < limit then push(nb, c, v, d + 1, ch) end
                -- this letter was left out, the tap is the next one
                local om = cost + omitCost(ch, last, d)
                if om < limit then
                    local g = child[c]
                    while g ~= 0 do
                        local gh = chr[g]
                        v = om + M[base + gh]
                        if v < limit then push(nb, g, v, d + 2, gh) end
                        g = sib[g]
                    end
                end
                -- this tap and the next were swapped: the next letter first
                if i < n and cost + p.swap < limit then
                    local g = child[c]
                    while g ~= 0 do
                        local gh = chr[g]
                        v = cost + M[base + gh] + M[base + NSYM + ch] + p.swap
                        if v < limit then
                            nxt_after[i + 1] = nxt_after[i + 1] or newBeam()
                            push(nxt_after[i + 1], g, v, d + 2, gh)
                        end
                        g = sib[g]
                    end
                end
                c = sib[c]
            end
        end
        if nxt_after[i + 1] and i + 1 > n then nxt_after[i + 1] = nil end
        cur = prune(nb)
    end

    -- words: the states left, and one more left-out letter at the end
    local cands, list = {}, {}
    local function offer(w, cost, completion)
        if offensive[w] == 1 and w ~= lword then return end
        local c = cands[w]
        if c then
            if cost < c.cost then c.cost, c.completion = cost, completion end
            return
        end
        c = { w = w, cost = cost, completion = completion }
        cands[w] = c
        list[#list + 1] = c
    end
    for k = 1, cur.n do
        local node, cost, d, last = cur.node[k], cur.cost[k], cur.d[k], cur.last[k]
        local w = wordat[node]
        while w ~= 0 do
            offer(w, cost + self:lmCost(w), false)
            w = nextw[w]
        end
        local c = child[node]
        while c ~= 0 do
            local w2 = wordat[c]
            if w2 ~= 0 then
                local om = omitCost(chr[c], last, d)
                while w2 ~= 0 do
                    offer(w2, cost + om + self:lmCost(w2), false)
                    w2 = nextw[w2]
                end
            end
            c = sib[c]
        end
        local b = below[node]
        if b ~= 0 and d > 0 then offer(b, cost + p.comp * (wlen[b] - d) + self:lmCost(b), true) end
    end
    table.sort(list, function(a, b) return a.cost < b.cost end)
    while #list > p.keep do list[#list] = nil end

    local cap = literal:sub(1, 1):match("%u") ~= nil
    local function shown(w)
        local s = self:word(w)
        if cap then s = s:sub(1, 1):upper() .. s:sub(2) end
        return s
    end
    for _, c in ipairs(list) do
        result.cands[#result.cands + 1] = { word = shown(c.w), cost = c.cost, completion = c.completion, w = c.w }
    end

    -- the correction a space would make: AOSP's always-corrections first, then the likeliest other word when it
    -- beats the word as typed by the margin and needs no more far edits than the word's length allows, then only
    -- the capital a word always has ("i", "elizabeth")
    local sc = not valid and self.shortcuts[lkey]
    if sc then
        result.fix = cap and (sc:sub(1, 1):upper() .. sc:sub(2)) or sc
        return result
    end
    if n >= 2 then -- one letter on its own ("a", "o") is left alone
        -- Far edits allowed: none away from a real word ("hmm" isn't "him") or in a short one, where a letter
        -- more or less is a different word as often as a slip ("rn", "omg", "smth" stay); one up to seven letters
        -- ("qustion"), two in longer ones ("definately": a and i aren't neighbours).
        local allowed = (lword ~= 0 or n <= 4) and 0 or n <= 7 and 1 or 2
        for _, c in ipairs(list) do
            if not c.completion and c.w ~= lword then
                if self.wnode[c.w] ~= lnode and c.cost + p.margin < lit_cost
                        and self:farEdits(M, tcode, n, self:codes(c.w)) <= allowed then
                    result.fix = shown(c.w)
                    return result
                end
                break
            end
        end
    end
    if lword ~= 0 and not opts.known and literal == lkey then
        local w, lower_form = lword, false
        while w ~= 0 do
            if self:word(w) == lkey then lower_form = true end
            w = nextw[w]
        end
        -- a name's capital ("london"), and I; not an acronym's: "ok", "dm", "ai" stay as typed
        local first = self:word(lword)
        if not lower_form and first:match("^%u[^%u]*$") and (n > 1 or lkey == "i") then result.fix = first end
    end
    return result
end

return Decoder
