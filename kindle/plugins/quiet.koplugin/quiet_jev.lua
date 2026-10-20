--[[
Quiet Jev: TypeSafe AI's Jev answers typed questions about a piece of text in about a third of a second: pick
one of up to 255 options, place it on a scale, or say yes or no, each with probabilities. It writes nothing;
it decides. Search & Ask uses it to tell what was typed (words to find, a moment, a question, a place) and to
rank passages by meaning.

    Jev.available()
    Jev.choice{ state = "what the reader typed", question = "Which passage is the reader looking for?",
        options = { "…", "…" },              -- up to 255, best guess first (Jev leans towards the first)
        callback = function(res, err, info) end }
        -- res.index (1-based), res.label (= options[index]), res.probabilities[i], res.confidence (0..1)
    Jev.yesno{ state = "…", question = "…", yes = "what yes means", no = "what no means", callback = … }
        -- res.p (0..1), res.yes (p >= 0.5)
    Jev.score{ state = "…", question = "…", levels = { "lowest", …, "highest" }, callback = … }   -- 2 to 10
        -- res.score (1-based, between levels), res.level (rounded), res.probabilities[i], res.confidence
    Jev.ask{ state = "…", questions = { name = { type = "choice"|"noul"|"score", instructions = "…",
        criteria = … } }, callback = function(answers, err, info) end }
        -- several questions about one text in one call, at the latency of one; answers are the raw API ones.
        -- Tables are sent with sorted keys unless they carry __order = { "key", … }: give a choice's criteria
        -- one, or its options get shuffled into alphabetical order.

Calls don't switch Wi-Fi on (pass wake_wifi = true to allow it): without Wi-Fi the callback gets
(nil, "offline") straight away, so offline search never waits on Jev. A call takes ~0.3-0.5 s.

API (docs.typesafe.ai, checked with live calls on 2026-10-19): POST https://api.typesafe.ai/v1/systemone,
Authorization: Bearer <key>, body {state, model = "jev-latest", questions = {<name> = {type, instructions,
criteria}}}. choice criteria: {option = description} (1-255, order matters); score criteria: 2-10 level
descriptions, low to high; noul criteria: optional {true = …, false = …}. Answers come back under the same
names: choice → choice, probabilities {option = p}, confidence; score → score (0-based level units), legend,
probabilities {"0" = p, …}, confidence; noul → noul (0..1). Errors: {"detail": {"error_type", "message"}} or
a validation list; 400 also means "too much text" (max_tokens_exceeded), 401 bad key, 422 invalid, 429/529 busy.
Context is about 64K tokens; accuracy drops with unrelated text, so send short, pre-filtered options.
]]

local Keys = require("quiet_keys")
local Net = require("quiet_net")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local rapidjson = require("rapidjson")

local Jev = {}

local URL = "https://api.typesafe.ai/v1/systemone"
local MODEL = "jev-latest"
local MAX_OPTIONS = 255

local warned_via

function Jev.available()
    local key, via = Keys.jev()
    if not key then return false end
    if via ~= "typesafe" then
        if not warned_via then
            warned_via = true
            logger.warn("quiet jev: only TypeSafe's own API is supported, not", via)
        end
        return false
    end
    return true
end

-- JSON with object keys in the order given: {__order = {"a", "b"}, a = …, b = …}. Jev reads choice options
-- in order and leans towards the first, so the order has to survive encoding.
local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode(v, out)
    local t = type(v)
    if t == "string" then
        out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end) .. '"'
    elseif t == "number" then
        out[#out + 1] = string.format("%.14g", v)
    elseif t == "boolean" then
        out[#out + 1] = tostring(v)
    elseif v == nil or v == rapidjson.null then
        out[#out + 1] = "null"
    elseif t == "table" then
        if v.__order or next(v) == nil or v[1] == nil then
            local keys = v.__order
            if not keys then
                keys = {}
                for k in pairs(v) do keys[#keys + 1] = tostring(k) end
                table.sort(keys)
            end
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                encode(k, out)
                out[#out + 1] = ":"
                encode(v[k], out)
            end
            out[#out + 1] = "}"
        else
            out[#out + 1] = "["
            for i, item in ipairs(v) do
                if i > 1 then out[#out + 1] = "," end
                encode(item, out)
            end
            out[#out + 1] = "]"
        end
    else
        error("quiet jev: can't encode a " .. t)
    end
end

function Jev._encode(v)
    local out = {}
    encode(v, out)
    return table.concat(out)
end

-- Option names "1", "2", … padded to one width, so the API's answer maps straight back to an index.
function Jev._labels(n)
    local width = #tostring(n)
    local labels = {}
    for i = 1, n do labels[i] = string.format("%0" .. width .. "d", i) end
    return labels
end

local function decodeError(code, body)
    local ok, parsed = pcall(rapidjson.decode, body)
    local detail = ok and type(parsed) == "table" and parsed.detail
    local etype, message
    if type(detail) == "table" then
        etype = type(detail.error_type) == "string" and detail.error_type or nil
        message = type(detail.message) == "string" and detail.message or nil
        if not message and type(detail[1]) == "table" and type(detail[1].msg) == "string" then
            message = detail[1].msg
        end
    end
    local text
    if code == 401 or code == 403 then
        text = "Jev didn't accept the key."
    elseif code == 429 or code == 529 then
        text = "Jev is busy."
    elseif code == 400 and message and message:find("max_tokens", 1, true) then
        text = "Too much text for Jev."
    elseif code == 413 then
        text = "Too much text for Jev."
    else
        text = "Jev couldn't answer (" .. code .. ")."
    end
    return text, { kind = "http", code = code, error_type = etype, detail = message }
end

local NET_ERRORS = {
    offline = "Couldn't reach Jev.", timeout = "Jev took too long.", tls = "Couldn't make a secure connection to Jev.",
    closed = "The connection to Jev dropped.", other = "Network error.",
}

-- One call: questions is {name = {type, instructions, criteria}}; callback(answers, err, info).
function Jev.ask(opts)
    local cb = opts.callback or function() end
    local function finish(answers, err, info)
        local ok, e = pcall(cb, answers, err, info or {})
        if not ok then logger.warn("quiet jev: callback failed", e) end
    end
    local key = Keys.jev()
    if not key or not Jev.available() then
        UIManager:nextTick(function() finish(nil, "No Jev key on this Kindle", { kind = "nokey" }) end)
        return { cancel = function() end }
    end
    local ok, body = pcall(Jev._encode, {
        __order = { "state", "model", "questions" },
        state = opts.state or "", model = opts.model or MODEL, questions = opts.questions,
    })
    if not ok then
        UIManager:nextTick(function() finish(nil, "Jev couldn't take this request", { kind = "request", detail = body }) end)
        return { cancel = function() end }
    end
    local job = { cancelled = false, attempt = 0 }
    local function send()
        job.attempt = job.attempt + 1
        job.req = Net.request{
            url = URL, method = "POST", body = body, label = "jev",
            headers = { ["content-type"] = "application/json", ["authorization"] = "Bearer " .. key },
            timeout = opts.timeout or 10, total_timeout = (opts.timeout or 10) + 5,
            on_done = function(code, resp, net_info)
                if job.cancelled then return end
                if code == 200 then
                    local okd, parsed = pcall(rapidjson.decode, resp)
                    if okd and type(parsed) == "table" and type(parsed.answers) == "table" then
                        logger.dbg("quiet jev:", net_info.ms, "ms")
                        return finish(parsed.answers, nil, { ms = net_info.ms, usage = parsed.usage, model = parsed.model })
                    end
                    return finish(nil, "Jev's answer didn't make sense", { kind = "parse" })
                end
                if (code == 429 or code == 529) and job.attempt < 2 then
                    return UIManager:scheduleIn(0.6, function() if not job.cancelled then send() end end)
                end
                local text, info = decodeError(code, resp)
                info.ms = net_info.ms
                logger.info("quiet jev: HTTP", code, info.error_type or "", info.detail or "")
                finish(nil, text, info)
            end,
            on_error = function(_, net_info)
                if job.cancelled then return end
                finish(nil, NET_ERRORS[net_info.kind] or NET_ERRORS.other, { kind = net_info.kind, detail = net_info.detail })
            end,
        }
    end
    function job.cancel()
        job.cancelled = true
        if job.wifi and job.wifi.cancel then job.wifi.cancel() end
        if job.req then job.req:cancel() end
    end
    if Net.isOnline() then
        send()
    elseif opts.wake_wifi then
        job.wifi = Net.whenOnline(function() if not job.cancelled then send() end end,
            function(message) if not job.cancelled then finish(nil, message, { kind = "wifi" }) end end)
    else
        UIManager:nextTick(function() if not job.cancelled then finish(nil, "offline", { kind = "offline" }) end end)
    end
    return job
end

-- Probabilities keyed by option name -> array in option order.
local function aligned(probs, names)
    local out = {}
    for i, name in ipairs(names) do
        out[i] = type(probs) == "table" and tonumber(probs[name]) or 0
    end
    return out
end

function Jev.choice(opts)
    local options = opts.options or {}
    local cb = opts.callback or function() end
    if #options == 0 or #options > MAX_OPTIONS then
        UIManager:nextTick(function() cb(nil, "Jev takes 1 to 255 options", { kind = "request" }) end)
        return { cancel = function() end }
    end
    local labels = Jev._labels(#options)
    local criteria = { __order = labels }
    for i, label in ipairs(labels) do criteria[label] = tostring(options[i]) end
    return Jev.ask{
        state = opts.state, timeout = opts.timeout, wake_wifi = opts.wake_wifi,
        questions = { q = { __order = { "type", "instructions", "criteria" }, type = "choice",
            instructions = opts.question, criteria = criteria } },
        callback = function(answers, err, info)
            local a = answers and answers.q
            if type(a) ~= "table" then return cb(nil, err or "Jev gave no answer", info) end
            local index = tonumber(a.choice)
            if not index or not options[index] then return cb(nil, "Jev's answer didn't make sense", info) end
            cb({ index = index, label = options[index], probabilities = aligned(a.probabilities, labels),
                confidence = tonumber(a.confidence) }, nil, info)
        end,
    }
end

function Jev.yesno(opts)
    local cb = opts.callback or function() end
    local q = { __order = { "type", "instructions" }, type = "noul", instructions = opts.question }
    if opts.yes or opts.no then
        q.__order[3] = "criteria"
        q.criteria = { __order = { "true", "false" }, ["true"] = opts.yes or "Yes", ["false"] = opts.no or "No" }
    end
    return Jev.ask{
        state = opts.state, timeout = opts.timeout, wake_wifi = opts.wake_wifi, questions = { q = q },
        callback = function(answers, err, info)
            local a = answers and answers.q
            local p = type(a) == "table" and tonumber(a.noul)
            if not p then return cb(nil, err or "Jev gave no answer", info) end
            cb({ p = p, yes = p >= 0.5 }, nil, info)
        end,
    }
end

function Jev.score(opts)
    local levels = opts.levels or {}
    local cb = opts.callback or function() end
    if #levels < 2 or #levels > 10 then
        UIManager:nextTick(function() cb(nil, "Jev takes 2 to 10 levels", { kind = "request" }) end)
        return { cancel = function() end }
    end
    local names = {}
    for i = 1, #levels do names[i] = tostring(i - 1) end
    return Jev.ask{
        state = opts.state, timeout = opts.timeout, wake_wifi = opts.wake_wifi,
        questions = { q = { __order = { "type", "instructions", "criteria" }, type = "score",
            instructions = opts.question, criteria = levels } },
        callback = function(answers, err, info)
            local a = answers and answers.q
            local s = type(a) == "table" and tonumber(a.score)
            if not s then return cb(nil, err or "Jev gave no answer", info) end
            local level = math.max(1, math.min(#levels, math.floor(s + 0.5) + 1))
            cb({ score = s + 1, level = level, probabilities = aligned(a.probabilities, names),
                confidence = tonumber(a.confidence) }, nil, info)
        end,
    }
end

return Jev
