--[[
eval.lua: how well the keyboard's decoder (kindle/patches/quiet-decoder.lua) corrects typing, measured offline.

  luajit tools/keyboard-eval/eval.lua WORDS.gz KEYS.lua CORPUS.txt [words=3000] [seed=1] [noise=0.27] [name=value ...]

WORDS.gz  kindle/data/quiet-keyboard/en.words.gz
KEYS.lua  returns { centres = { a = { x, y }, ... }, key_w = , key_h = }: the letter keys of the keyboard as the
          Kindle's keymap places them (make it from the device's keymap; it isn't in this repo)
CORPUS    any English plain text (e.g. a public-domain novel): its words, in order, are what gets "typed"
name=value  a decoder parameter (see Decoder.PARAMS), or noise (the spread of taps around a key, in key widths;
          0.27 puts ~8.5% of taps on another key, the per-letter error rate Google measured for touch typing),
          sim_omit / sim_extra / sim_swap (per-letter rates of those slips in the simulation)

Typing is simulated: every letter's tap lands around its key's centre (a Gaussian), the key under it is what gets
typed, and now and then a letter is left out, a tap is added (on that key or a neighbour) or two letters are swapped.
Each word is typed in lower case, as on a keyboard without auto-capitals. Then the decoder decides, as a space would.
Reported: words right as typed, right after correction, wrong words corrected, right words wrongly corrected, the
word among the three suggestions; apart for words in the list and words not in it (names, mostly). Then the slips
from real typing (fixed and kept lists below), and the time per word.
]]

local here = (arg[0]:match("^(.*)/") or ".") .. "/"
local Decoder = dofile(here .. "../../kindle/patches/quiet-decoder.lua")

local words_path, keys_path, corpus_path = arg[1], arg[2], arg[3]
assert(words_path and keys_path and corpus_path, "usage: eval.lua WORDS.gz KEYS.lua CORPUS.txt [name=value ...]")
local opt = { words = 3000, seed = 1, noise = 0.27, sim_omit = 0.01, sim_extra = 0.01, sim_swap = 0.005 }
local params = {}
for i = 4, #arg do
    local k, v = arg[i]:match("^([%w_]+)=(.+)$")
    if k then
        if opt[k] ~= nil then opt[k] = tonumber(v) else params[k] = tonumber(v) end
    end
end

local t0 = os.clock()
local dec = assert(Decoder.load(words_path, { params = params }))
local keys = dofile(keys_path)
dec:setKeys(keys.centres, keys.key_w, keys.key_h)
io.stderr:write(string.format("loaded %d words in %.2f s\n", dec.nwords, os.clock() - t0))

math.randomseed(opt.seed)
local function gauss()
    local u1, u2 = math.random(), math.random()
    return math.sqrt(-2 * math.log(u1 + 1e-12)) * math.cos(2 * math.pi * u2)
end
local C, KW, KH = keys.centres, keys.key_w, keys.key_h
local letters = {}
for ch in pairs(C) do letters[#letters + 1] = ch end
local function nearest(x, y)
    local best, bd
    for _, ch in ipairs(letters) do
        local c = C[ch]
        local d = ((x - c[1]) / KW) ^ 2 + ((y - c[2]) / KH) ^ 2
        if not bd or d < bd then best, bd = ch, d end
    end
    return best
end
local function neighbour(ch)
    local c, list = C[ch], {}
    for _, o in ipairs(letters) do
        local d = C[o]
        if o ~= ch and ((c[1] - d[1]) / KW) ^ 2 + ((c[2] - d[2]) / KH) ^ 2 < 2.3 then list[#list + 1] = o end
    end
    return list[math.random(#list)]
end

local wrong_taps, all_taps = 0, 0
-- the taps of one word typed with slips: { { ch, x, y }, ... }
local function typeWord(word)
    local chars = {}
    for ch in word:gmatch(".") do chars[#chars + 1] = ch end
    local i = 1
    while i < #chars do -- swaps
        if chars[i]:match("%a") and chars[i + 1]:match("%a") and math.random() < opt.sim_swap then
            chars[i], chars[i + 1] = chars[i + 1], chars[i]
            i = i + 1
        end
        i = i + 1
    end
    local taps = {}
    local function tap(ch)
        if ch == "'" then
            taps[#taps + 1] = { ch = "'" }
            return
        end
        local c = C[ch]
        if not c then return end
        local x, y = c[1] + gauss() * opt.noise * KW, c[2] + gauss() * opt.noise * KH
        local got = nearest(x, y)
        all_taps = all_taps + 1
        if got ~= ch then wrong_taps = wrong_taps + 1 end
        taps[#taps + 1] = { ch = got, x = x, y = y }
    end
    for _, ch in ipairs(chars) do
        if math.random() >= opt.sim_omit then tap(ch) end
        if math.random() < opt.sim_extra then tap(math.random() < 0.5 and ch or neighbour(ch) or ch) end
    end
    return taps
end

-- the corpus's words (letters and apostrophes), skipping Project Gutenberg's header and licence
local text = assert(io.open(corpus_path)):read("*a")
text = text:match("%*%*%* ?START OF.-%*%*%*(.*)%*%*%* ?END OF") or text
local corpus = {}
for w in text:gmatch("[%a][%a']*") do
    w = w:gsub("'+$", "")
    if #w > 0 then corpus[#corpus + 1] = w end
end

local function inList(w)
    return dec:find(w:lower()) ~= nil and dec.wordat[dec:find(w:lower())] ~= 0
end

local stats = { iv = {}, oov = {} }
for _, s in pairs(stats) do
    s.n, s.lit, s.final, s.fixed, s.broke, s.wrong, s.top3 = 0, 0, 0, 0, 0, 0, 0
end
local decode_time, decodes = 0, 0
local start = math.random(math.max(1, #corpus - opt.words))
local samples, missed = {}, {}
for k = start, math.min(#corpus, start + opt.words - 1) do
    local word = corpus[k]:lower()
    local taps = typeWord(word)
    if #taps > 0 then
        local lit = {}
        for _, t in ipairs(taps) do lit[#lit + 1] = t.ch end
        lit = table.concat(lit)
        local t1 = os.clock()
        local r = dec:decode(taps)
        decode_time, decodes = decode_time + (os.clock() - t1), decodes + 1
        local final = (r.fix or lit):lower()
        local s = inList(word) and stats.iv or stats.oov
        s.n = s.n + 1
        local lit_ok, final_ok = lit == word, final == word
        if lit_ok then s.lit = s.lit + 1 end
        if final_ok then s.final = s.final + 1 end
        if not lit_ok then
            s.wrong = s.wrong + 1
            if not final_ok and inList(lit) then s.lit_word = (s.lit_word or 0) + 1 end
            if final_ok then
                s.fixed = s.fixed + 1
            elseif s == stats.iv and #missed < 25 then
                missed[#missed + 1] = lit .. ">" .. final .. "(" .. word .. ")"
            end
        elseif not final_ok then
            s.broke = s.broke + 1
            if #samples < 12 then samples[#samples + 1] = word .. " -> " .. final end
        end
        local shown = {}
        if r.fix then shown[#shown + 1] = r.fix:lower() end
        for _, c in ipairs(r.cands) do
            if #shown >= 3 then break end
            shown[#shown + 1] = c.word:lower()
        end
        for _, w in ipairs(shown) do
            if w == word then s.top3 = s.top3 + 1 break end
        end
    end
end

local function pct(a, b) return b > 0 and string.format("%5.1f%%", 100 * a / b) or "   - " end
print(string.format("taps on the wrong key: %s (noise %.2f)", pct(wrong_taps, all_taps), opt.noise))
for _, kind in ipairs({ "iv", "oov" }) do
    local s = stats[kind]
    print(string.format("%-14s n=%-5d typed right %s  after correction %s  wrong ones fixed %s  right ones broken %s  in top 3 %s",
        kind == "iv" and "in the list" or "not in it", s.n, pct(s.lit, s.n), pct(s.final, s.n), pct(s.fixed, s.wrong),
        pct(s.broke, s.n - s.wrong), pct(s.top3, s.n)))
end
local iv = stats.iv
print(string.format("not fixed: %d words, %d of them typed as another real word (only the sentence could tell)",
    iv.wrong - iv.fixed, iv.lit_word or 0))
if #samples > 0 then print("broken: " .. table.concat(samples, ", ")) end
if #missed > 0 then print("not fixed: " .. table.concat(missed, " ")) end

-- slips from real typing: typed (as key centres) -> wanted
local fixed = {
    { "thw", "the" }, { "teh", "the" }, { "realy", "really" }, { "keybaord", "keyboard" },
    { "funcitnal", "functional" }, { "reasoinng", "reasoning" }, { "buhhy", "buggy" }, { "recieve", "receive" },
    { "definately", "definitely" }, { "becuase", "because" }, { "wierd", "weird" }, { "seperately", "separately" },
    { "accomodate", "accommodate" }, { "dont", "don't" }, { "im", "I'm" }, { "i", "I" }, { "wjat", "what" },
    { "tjis", "this" }, { "helo", "hello" }, { "qustion", "question" }, { "happend", "happened" },
}
-- words that must stay as typed (names from public-domain novels, none in the list), lower case and capitalised
local kept = { "houyhnhnm", "bagheera", "stubb", "wickham", "clerval", "heathcliff", "queequeg", "fogg", "pumblechook",
    "javert", "kaa", "marilla", "magwitch", "valjean", "hindley", "nemo", "daggoo", "tashtego", "raskolnikov", "havisham" }
local function tapsOf(s)
    local t = {}
    for ch in s:gmatch(".") do t[#t + 1] = { ch = ch } end
    return t
end
local ok, line = 0, {}
for _, c in ipairs(fixed) do
    local r = dec:decode(tapsOf(c[1]))
    local got = r.fix or c[1]
    local good = got == c[2]
    if good then ok = ok + 1 end
    line[#line + 1] = c[1] .. ">" .. got .. (good and "" or "(" .. ((r.cands[1] or {}).word or "-") .. ")")
end
print(string.format("real slips fixed: %d/%d  %s", ok, #fixed, table.concat(line, " ")))
local stayed, broken = 0, {}
for _, w in ipairs(kept) do
    for _, form in ipairs({ w, w:sub(1, 1):upper() .. w:sub(2) }) do
        local r = dec:decode(tapsOf(form))
        if not r.fix or r.fix:lower() == form:lower() then stayed = stayed + 1 else broken[#broken + 1] = form .. ">" .. r.fix end
    end
end
print(string.format("names kept: %d/%d  %s", stayed, 2 * #kept, table.concat(broken, " ")))
-- typed as people type in messages: never "corrected" (a capital added counts as a change too)
local informal = { "ur", "rn", "idk", "u", "bro", "lol", "ok", "ty", "thx", "pls", "btw", "tbh", "omg", "lmao", "imo",
    "gonna", "wanna", "kinda", "ya", "yea", "nah", "smth", "abt", "wat", "hmm", "ik", "ui", "fr", "ngl", "lmk", "nvm",
    "dm", "ai", "tv" }
local same, changed = 0, {}
for _, w in ipairs(informal) do
    local r = dec:decode(tapsOf(w))
    if not r.fix or r.fix == w then same = same + 1 else changed[#changed + 1] = w .. ">" .. r.fix end
end
print(string.format("informal kept: %d/%d  %s", same, #informal, table.concat(changed, " ")))
print(string.format("decode: %.2f ms per word (this machine)", 1000 * decode_time / math.max(1, decodes)))
