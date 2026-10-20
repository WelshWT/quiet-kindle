--[[
Quiet Claude: Anthropic's Messages API, streamed, for Search & Ask. Runs through quiet_net, so the page never
freezes while Claude thinks. Also the one door to whichever AI the Kindle has (provider, name, models): with an
OpenAI-compatible service in keys.lua, stream() hands over to quiet_openai.lua; with none, available() is false.

    local job = Claude.stream{
        model = "claude-opus-5-5", effort = "medium", system = "…",
        book = { { text = "…", cache = true }, { text = "…" } },  -- first in the first user turn
        turns = { { role = "user", text = "…" }, { role = "assistant", text = "…" }, … },  -- ends with the reader
        max_tokens = 8192,                      -- optional; Claude's thinking counts toward it
        on_text = function(delta, so_far) end,  -- answer text only, once per batch of text that arrived
        on_done = function(text, info) end,     -- info: model, stop_reason, usage, cost, ms, first_text_ms
        on_error = function(message, info) end, -- short words for the reader; info.kind, info.partial
    }
    job:cancel()                                -- silent: no callback afterwards

What this follows (the Claude API reference bundled with Claude Code, checked with live calls on 2026-10-19):
  - All three models think adaptively and always: no `thinking` field is sent (budget_tokens is a 400, and
    "disabled" is a 400 on Opus and Sonnet 5.5). How much they think is output_config.effort: low, medium,
    high, xhigh or max on all three. API defaults: Opus 5.5 medium, Sonnet 5.5 high, Haiku 5.5 medium.
  - Thinking text comes back empty (display "omitted"), in its own blocks; only text_delta is the answer.
  - cache_control {type = "ephemeral"} (5 minutes, renewed on every hit; ttl = "1h" also exists but writes
    cost 2x input instead of 1.25x, which only pays from the third question in the same chapter) needs no beta header; at most 4 breakpoints; prefixes under
    512 tokens just don't cache. Changing model or effort starts a new cache.
  - Safety classifiers can stop an answer: HTTP 200 with stop_reason "refusal". Opus and Sonnet 5.5 get
    fallbacks = "default" (beta server-side-fallback-2026-07-01), which retries some refusal categories on
    another model in the same stream. Haiku 5.5 has no fallback (a list there is a 400).
  - Errors are JSON {type = "error", error = {type, message}}: 400 invalid_request, 401 authentication,
    402 billing, 403 permission, 404 not_found, 413 request_too_large, 429 rate_limit, 500 api, 529 overloaded.
    The last two can also arrive mid-stream as an "error" event.
]]

local Keys = require("quiet_keys")
local Net = require("quiet_net")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local rapidjson = require("rapidjson")

local Claude = {}

Claude.MODELS = {
    { id = "claude-opus-5-5", label = "Opus 5.5" },
    { id = "claude-sonnet-5-5", label = "Sonnet 5.5" },
    { id = "claude-haiku-5-5", label = "Haiku 5.5" },
}

Claude.EFFORTS = {
    { id = "low", label = "Low" },
    { id = "medium", label = "Medium" },
    { id = "high", label = "High" },
    { id = "xhigh", label = "Extra high" },
    { id = "max", label = "Max" },
}

Claude.DEFAULT_MODEL = "claude-opus-5-5"
Claude.DEFAULT_EFFORT = "medium"

local API_URL = "https://api.anthropic.com/v1/messages"
local API_VERSION = "2023-06-01"
local FALLBACK_BETA = "server-side-fallback-2026-07-01"
local ALL_EFFORTS = { low = true, medium = true, high = true, xhigh = true, max = true }

-- What each model takes. A model not listed here gets neither effort nor fallbacks.
-- Prices in USD per million tokens: input, output, 5-minute cache write (1.25x input), cache read.
local MODEL = {
    ["claude-opus-5-5"] = { efforts = ALL_EFFORTS, fallbacks = true, price = { 4, 20, 5, 0.20 } },
    ["claude-sonnet-5-5"] = { efforts = ALL_EFFORTS, fallbacks = true, price = { 2, 10, 2.5, 0.20 } },
    ["claude-haiku-5-5"] = { efforts = ALL_EFFORTS, fallbacks = false, price = { 0.10, 0.50, 0.125, 0.01 },
        long_price = { 0.50, 2.50, 0.625, 0.05 } }, -- prompts over 100K tokens
}

-- Room for thinking plus a short answer.
local MAX_TOKENS = { low = 4096, medium = 8192, high = 16384, xhigh = 32768, max = 64000 }

local function find(list, id)
    for _, item in ipairs(list) do
        if item.id == id then return item end
    end
end

-- Which AI answers: an OpenAI-compatible service when keys.lua has `ai` (quiet_openai.lua), else Claude when
-- there's an Anthropic key, else none (Search & Ask stays offline and the ask buttons hide).
local function aiConfig() return Keys.ai and Keys.ai() or nil end

function Claude.provider()
    if aiConfig() then return "openai" end
    if Keys.anthropic() then return "anthropic" end
end

function Claude.available()
    return Claude.provider() ~= nil
end

-- What the buttons and the answers call it.
function Claude.name()
    local ai = aiConfig()
    if ai then return ai.name end
    return "Claude"
end

-- Who answers, as one string: a conversation belongs to it, and a different one starts a new conversation (review
-- C8-4, round 2): Claude, or the service's address, model and book budget.
function Claude.identity()
    local ai = aiConfig()
    if ai then return table.concat({ "openai", ai.url, ai.model, tostring(Claude.bookChars()) }, "|") end
    if Keys.anthropic() then return "anthropic" end
    return "none"
end

-- The models and efforts to choose between: Claude's, or the one model keys.lua names (with no effort levels).
function Claude.models()
    local ai = aiConfig()
    if ai then return { { id = ai.model, label = ai.model } } end
    return Claude.MODELS
end

function Claude.efforts()
    if aiConfig() then return {} end
    return Claude.EFFORTS
end

-- How much of the earlier chapters to send, in characters (about four a token), or nil for quiet_bookctx's own
-- ~100k tokens (Claude). Another service's context window can be far smaller: book_tokens, 30000 by default.
function Claude.bookChars()
    local ai = aiConfig()
    if ai then return math.floor((ai.book_tokens or 30000) * 4) end
end

function Claude.modelLabel(id)
    local m = find(Claude.MODELS, id)
    return m and m.label or tostring(id)
end

function Claude.effortLabel(id)
    local e = find(Claude.EFFORTS, id)
    return e and e.label or tostring(id)
end

-- Does this model take this effort level? (false for models we don't know)
function Claude.supportsEffort(model, effort)
    local m = MODEL[model]
    return m ~= nil and m.efforts[effort] == true
end

-- Rough USD cost of one answer from its usage (5-minute cache writes assumed).
function Claude.cost(model, usage)
    local m = MODEL[model]
    if not m or type(usage) ~= "table" then return nil end
    local input = (usage.input_tokens or 0)
    local write = (usage.cache_creation_input_tokens or 0)
    local read = (usage.cache_read_input_tokens or 0)
    local p = m.price
    if m.long_price and input + write + read > 100000 then p = m.long_price end
    return (input * p[1] + (usage.output_tokens or 0) * p[2] + write * p[3] + read * p[4]) / 1e6
end

-- The request body (a Lua table) and headers without the key, or nil and why.
function Claude.buildRequest(opts)
    local model = opts.model or Claude.DEFAULT_MODEL
    local m = MODEL[model]
    local effort = opts.effort or Claude.DEFAULT_EFFORT
    if not (m and m.efforts[effort]) then effort = nil end

    -- turns: drop empty ones, merge neighbours from the same side; the reader speaks first and last
    local turns = {}
    for _, t in ipairs(opts.turns or {}) do
        local text = t.text or ""
        if text:find("%S") then
            local role = t.role == "assistant" and "assistant" or "user"
            local last = turns[#turns]
            if last and last.role == role then
                last.text = last.text .. "\n\n" .. text
            else
                turns[#turns + 1] = { role = role, text = text }
            end
        end
    end
    if #turns == 0 then return nil, "nothing to ask" end
    if turns[1].role ~= "user" then return nil, "the conversation has to start with the reader" end
    if turns[#turns].role ~= "user" then return nil, "the conversation has to end with the reader" end

    local content, cached = {}, {}
    for _, b in ipairs(opts.book or {}) do
        if type(b.text) == "string" and b.text:find("%S") then
            content[#content + 1] = { type = "text", text = b.text }
            if b.cache then cached[#cached + 1] = #content end
        end
    end
    -- at most four breakpoints: the last ones mark the longest prefixes
    for i = math.max(1, #cached - 3), #cached do
        content[cached[i]].cache_control = { type = "ephemeral", ttl = opts.cache_ttl }
    end
    content[#content + 1] = { type = "text", text = turns[1].text }

    local messages = { { role = "user", content = content } }
    for i = 2, #turns do
        messages[#messages + 1] = { role = turns[i].role, content = turns[i].text }
    end

    local body = {
        model = model,
        max_tokens = opts.max_tokens or MAX_TOKENS[effort or "medium"],
        stream = true,
        messages = messages,
    }
    if opts.system and opts.system:find("%S") then body.system = opts.system end
    if effort then body.output_config = { effort = effort } end
    local headers = { ["content-type"] = "application/json", ["anthropic-version"] = API_VERSION }
    if m and m.fallbacks then
        body.fallbacks = "default"
        headers["anthropic-beta"] = FALLBACK_BETA
    end
    return body, headers
end

-- Server-sent events, fed in chunks split anywhere: feed(chunk, on_event(name, data)).
function Claude._sse()
    local buf = ""
    local event, data = nil, {}
    return function(chunk, on_event)
        buf = buf .. chunk
        local pos = 1
        while true do
            local nl = buf:find("\n", pos, true)
            if not nl then break end
            local line = buf:sub(pos, nl - 1)
            pos = nl + 1
            if line:sub(-1) == "\r" then line = line:sub(1, -2) end
            if line == "" then
                if event or #data > 0 then on_event(event or "message", table.concat(data, "\n")) end
                event, data = nil, {}
            elseif line:sub(1, 1) ~= ":" then
                local field, value = line:match("^([^:]*):? ?(.*)$")
                if field == "event" then
                    event = value
                elseif field == "data" then
                    data[#data + 1] = value
                end
            end
        end
        buf = buf:sub(pos)
    end
end

local HTTP_ERRORS = {
    [400] = "Claude couldn't take this request.",
    [401] = "Claude didn't accept the key.",
    [402] = "Claude's billing needs attention (Anthropic console).",
    [403] = "This key can't use that Claude model.",
    [404] = "That Claude model isn't available.",
    [413] = "Too much text to send.",
    [429] = "Too many questions at once. Try again in a minute.",
    [500] = "Claude had a problem. Try again.",
    [529] = "Claude is busy. Try again in a moment.",
}
local ERROR_TYPES = {
    invalid_request_error = 400, authentication_error = 401, billing_error = 402, permission_error = 403,
    not_found_error = 404, request_too_large = 413, rate_limit_error = 429, api_error = 500,
    overloaded_error = 529,
}
local NET_ERRORS = {
    offline = "Couldn't reach Claude.",
    timeout = "Claude took too long.",
    tls = "Couldn't make a secure connection to Claude.",
    closed = "The connection to Claude dropped.",
    other = "Network error.",
}
local RETRYABLE = { [500] = true, [529] = true }

local Job = {}
Job.__index = Job

function Job:cancel()
    if self.finished then return end
    self.finished = true
    self.cancelled = true
    if self.wifi and self.wifi.cancel then self.wifi.cancel() end
    if self.retry_fn then UIManager:unschedule(self.retry_fn) end
    if self.req then self.req:cancel() end
end

function Job:fail(message, info)
    if self.finished then return end
    self.finished = true
    info = info or {}
    info.partial = self.text
    info.model = self.model
    logger.info("quiet claude:", self.model, self.effort or "-", "failed:", info.kind, info.code or "", info.detail or "")
    if self.opts.on_error then
        local ok, err = pcall(self.opts.on_error, message, info)
        if not ok then logger.warn("quiet claude: on_error failed", err) end
    end
end

-- Try once more after a short wait when Claude was busy and nothing had been said yet.
function Job:retryOr(message, info, wait)
    if self.attempt < 2 and self.text == "" and not self.cancelled then
        logger.info("quiet claude: retrying after", info.kind, info.code or "")
        self.retry_fn = function()
            self.retry_fn = nil
            self:start()
        end
        UIManager:scheduleIn(wait or 2, self.retry_fn)
        return
    end
    self:fail(message, info)
end

function Job:onEvent(name, data)
    if name == "ping" then return end
    local ok, ev = pcall(rapidjson.decode, data)
    if not ok or type(ev) ~= "table" then return end
    local t = ev.type or name
    if t == "message_start" then
        local msg = ev.message or {}
        self.model_used = msg.model or self.model_used
        self:addUsage(msg.usage)
    elseif t == "content_block_start" then
        local b = ev.content_block or {}
        if b.type == "fallback" then self.fell_back = true end
        if b.type == "text" and type(b.text) == "string" and b.text ~= "" then
            self.pending[#self.pending + 1] = b.text
        end
    elseif t == "content_block_delta" then
        local d = ev.delta or {}
        if d.type == "text_delta" and type(d.text) == "string" then
            self.pending[#self.pending + 1] = d.text
        end
    elseif t == "message_delta" then
        local d = ev.delta or {}
        if d.stop_reason and d.stop_reason ~= rapidjson.null then self.stop_reason = d.stop_reason end
        if type(d.stop_details) == "table" then self.stop_details = d.stop_details end
        self:addUsage(ev.usage)
    elseif t == "message_stop" then
        self.stopped = true
    elseif t == "error" then
        self.stream_error = type(ev.error) == "table" and ev.error or { type = "api_error" }
    end
end

function Job:addUsage(u)
    if type(u) ~= "table" then return end
    for _, k in ipairs({ "input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens" }) do
        if type(u[k]) == "number" then self.usage[k] = u[k] end
    end
end

function Job:onChunk(bytes)
    if self.finished then return end
    self.sse(bytes, self.on_event)
    if #self.pending == 0 then return end
    local delta = table.concat(self.pending)
    self.pending = {}
    self.text = self.text .. delta
    self.first_text_ms = self.first_text_ms or (self.req and self.req:info().ms)
    if self.opts.on_text then
        local ok, err = pcall(self.opts.on_text, delta, self.text)
        if not ok then logger.warn("quiet claude: on_text failed", err) end
    end
end

function Job:onDone(code, body, net_info)
    if self.finished then return end
    if code ~= 200 then
        local ok, parsed = pcall(rapidjson.decode, body)
        local e = ok and type(parsed) == "table" and type(parsed.error) == "table" and parsed.error or {}
        local info = { kind = "http", code = code, detail = type(e.message) == "string" and e.message or nil }
        local message = HTTP_ERRORS[code] or ("Claude answered with an error (" .. code .. ").")
        if RETRYABLE[code] then return self:retryOr(message, info) end
        if code == 429 and net_info.retry_after and net_info.retry_after <= 10 then
            return self:retryOr(message, info, net_info.retry_after)
        end
        return self:fail(message, info)
    end
    if self.stream_error then
        local c = ERROR_TYPES[self.stream_error.type] or 500
        local info = { kind = "http", code = c, detail = self.stream_error.message }
        local message = HTTP_ERRORS[c] or HTTP_ERRORS[500]
        if RETRYABLE[c] then return self:retryOr(message, info) end
        return self:fail(message, info)
    end
    if self.stop_reason == "refusal" then
        local d = self.stop_details or {}
        return self:fail("Claude declined to answer this.", { kind = "refusal", category = d.category })
    end
    if not self.stopped then
        return self:fail("The answer was cut off.", { kind = "cut" })
    end
    -- out of room: the answer's length (max_tokens) or the whole conversation's (the context window)
    if not self.text:find("%S") and (self.stop_reason == "max_tokens" or self.stop_reason == "model_context_window_exceeded") then
        return self:fail("Claude ran out of room. Try a lower effort.", { kind = "max_tokens" })
    end
    self.finished = true
    local info = {
        model = self.model_used or self.model, effort = self.effort, stop_reason = self.stop_reason,
        usage = self.usage, ms = net_info.ms, first_text_ms = self.first_text_ms, fell_back = self.fell_back,
    }
    info.cost = Claude.cost(self.model_used or self.model, self.usage)
    logger.info("quiet claude:", info.model, self.effort or "-", info.ms, "ms, first text", info.first_text_ms,
        "ms, in", self.usage.input_tokens, "cache w", self.usage.cache_creation_input_tokens,
        "r", self.usage.cache_read_input_tokens, "out", self.usage.output_tokens,
        info.cost and string.format("$%.4f", info.cost) or "")
    if self.opts.on_done then
        local ok, err = pcall(self.opts.on_done, self.text, info)
        if not ok then logger.warn("quiet claude: on_done failed", err) end
    end
end

function Job:start()
    if self.finished then return end
    self.attempt = self.attempt + 1
    self.text, self.pending, self.usage, self.first_text_ms = "", {}, {}, nil
    self.stopped, self.stop_reason, self.stop_details, self.stream_error = false, nil, nil, nil
    self.sse = Claude._sse()
    local key = Keys.anthropic()
    if not key then return self:fail("No Claude key on this Kindle.", { kind = "nokey" }) end
    local headers = {}
    for k, v in pairs(self.headers) do headers[k] = v end
    headers["x-api-key"] = key
    local slow = self.effort == "xhigh" or self.effort == "max"
    self.req = Net.request{
        url = API_URL, method = "POST", headers = headers, body = self.body, stream = true,
        label = "claude", timeout = 90, total_timeout = slow and 900 or 300,
        on_chunk = function(bytes) self:onChunk(bytes) end,
        on_done = function(code, body, info) self:onDone(code, body, info) end,
        on_error = function(_, info)
            local message = NET_ERRORS[info.kind] or NET_ERRORS.other
            local i = { kind = info.kind, detail = info.detail }
            if info.kind == "offline" or info.kind == "closed" then return self:retryOr(message, i) end
            self:fail(message, i)
        end,
    }
end

function Claude.stream(opts)
    if Claude.provider() == "openai" then return require("quiet_openai").stream(opts) end
    local job = setmetatable({ opts = opts, attempt = 0, text = "", usage = {} }, Job)
    job.on_event = function(name, data) job:onEvent(name, data) end
    local body, headers = Claude.buildRequest(opts)
    if not body then
        UIManager:nextTick(function() job:fail("Nothing to ask.", { kind = "request", detail = headers }) end)
        return job
    end
    job.model = body.model
    job.effort = body.output_config and body.output_config.effort
    job.headers = headers
    local ok, encoded = pcall(rapidjson.encode, body)
    if not ok or type(encoded) ~= "string" then
        UIManager:nextTick(function() job:fail("Nothing to ask.", { kind = "request", detail = tostring(encoded) }) end)
        return job
    end
    job.body = encoded
    if not Claude.available() then
        UIManager:nextTick(function() job:fail("No Claude key on this Kindle.", { kind = "nokey" }) end)
        return job
    end
    job.wifi = Net.whenOnline(function()
        if not job.finished then job:start() end
    end, function()
        job:fail("Couldn't get online. Check Wi-Fi and try again.", { kind = "wifi" })
    end)
    return job
end

return Claude
