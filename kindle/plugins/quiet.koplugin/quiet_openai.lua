--[[
Any OpenAI-compatible chat service for Search & Ask, when the Kindle has no Claude key (asked 20 Oct: "bring your
own AI key, it doesn't even have to be Claude"): OpenAI, OpenRouter, Gemini's OpenAI endpoint, Groq, Mistral, or a
local Ollama / LM Studio. Set in settings/quiet/keys.lua:

    ai = { url = "https://api.openai.com/v1", key = "sk-…", model = "gpt-5-mini", name = "ChatGPT" }

Same calls and callbacks as quiet_claude (Claude.stream hands over to OpenAI.stream), so the sheet treats both alike:
  - one system message, then the book and the first question in the first user message, then the conversation;
  - streamed chat completions: choices[1].delta.content is the answer (reasoning fields are skipped);
  - finish_reason "length" is the answer running out of room (stop_reason "max_tokens", shown as "Cut off here"),
    "content_filter" a refusal, a stream without [DONE] or a finish_reason a dropped answer;
  - no token limit is sent unless the file sets max_tokens (some models take max_tokens, others only
    max_completion_tokens; leaving it out works on all of them), and no prompt-cache fields (services that cache
    long prefixes do it by themselves).
]]

local Keys = require("quiet_keys")
local Net = require("quiet_net")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local rapidjson = require("rapidjson")

local OpenAI = {}

local function endpoint(url)
    url = url:gsub("/+$", "")
    if url:match("/chat/completions$") then return url end
    return url .. "/chat/completions"
end

-- The request body (a Lua table), or nil and why. Turns are cleaned up as quiet_claude does.
function OpenAI.buildRequest(opts, cfg)
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
    if turns[1].role ~= "user" or turns[#turns].role ~= "user" then return nil, "the reader speaks first and last" end

    local first = {}
    for _, b in ipairs(opts.book or {}) do
        if type(b.text) == "string" and b.text:find("%S") then first[#first + 1] = b.text end
    end
    first[#first + 1] = turns[1].text
    local messages = {}
    if opts.system and opts.system:find("%S") then messages[1] = { role = "system", content = opts.system } end
    messages[#messages + 1] = { role = "user", content = table.concat(first, "\n\n") }
    for i = 2, #turns do
        messages[#messages + 1] = { role = turns[i].role, content = turns[i].text }
    end
    local body = { model = cfg.model, stream = true, messages = messages }
    -- a limit only when keys.lua sets one, under the name that service takes (review C8-2): OpenAI's reasoning
    -- models take only max_completion_tokens, most other services max_tokens
    if cfg.max_completion_tokens then
        body.max_completion_tokens = cfg.max_completion_tokens
    elseif cfg.max_tokens then
        body.max_tokens = cfg.max_tokens
    end
    return body
end

local function messages(name)
    return {
        [400] = name .. " couldn't take this request.",
        [401] = name .. " didn't accept the key.",
        [402] = name .. "'s account needs attention (billing or credits).",
        [403] = "This key can't use that model.",
        [404] = "That model or address isn't there. Check keys.lua.",
        [413] = "Too much text to send. Set a smaller book_tokens in keys.lua.",
        [429] = "Too many questions at once, or out of credits. Try again in a minute.",
        [500] = name .. " had a problem. Try again.",
        [503] = name .. " is busy. Try again in a moment.",
    }
end
-- any server-side error is tried once more (review C8-8: 504 from a gateway too)
local function retryable(code) return code >= 500 and code <= 599 end

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
    info.model = self.cfg.model
    logger.info("quiet ai:", self.cfg.model, "failed:", info.kind, info.code or "", info.detail or "")
    if self.opts.on_error then
        local ok, err = pcall(self.opts.on_error, message, info)
        if not ok then logger.warn("quiet ai: on_error failed", err) end
    end
end

function Job:retryOr(message, info, wait)
    if self.attempt < 2 and self.text == "" and not self.cancelled then
        self.retry_fn = function()
            self.retry_fn = nil
            self:start()
        end
        UIManager:scheduleIn(wait or 2, self.retry_fn)
        return
    end
    self:fail(message, info)
end

function Job:onEvent(_, data)
    if data == "[DONE]" then
        self.done = true
        return
    end
    local ok, ev = pcall(rapidjson.decode, data)
    if not ok or type(ev) ~= "table" then return end
    if type(ev.error) == "table" then
        self.stream_error = ev.error
        return
    end
    self.model_used = type(ev.model) == "string" and ev.model or self.model_used
    local choice = type(ev.choices) == "table" and ev.choices[1]
    if type(choice) ~= "table" then return end
    local delta = choice.delta
    if type(delta) == "table" and type(delta.content) == "string" and delta.content ~= "" then
        self.pending[#self.pending + 1] = delta.content
    end
    -- OpenAI says a refusal in its own field, not in the content (review C8-7)
    if type(delta) == "table" and type(delta.refusal) == "string" and delta.refusal ~= "" then self.refused = true end
    if type(choice.finish_reason) == "string" then self.finish = choice.finish_reason end
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
        if not ok then logger.warn("quiet ai: on_text failed", err) end
    end
end

function Job:onDone(code, body, net_info)
    if self.finished then return end
    local words = messages(self.cfg.name)
    if code ~= 200 then
        local ok, parsed = pcall(rapidjson.decode, body)
        local e = ok and type(parsed) == "table" and type(parsed.error) == "table" and parsed.error or {}
        local info = { kind = "http", code = code, detail = type(e.message) == "string" and e.message or nil }
        local message = words[code] or (self.cfg.name .. " answered with an error (" .. code .. ").")
        if retryable(code) then return self:retryOr(message, info) end
        return self:fail(message, info)
    end
    if self.stream_error then
        local detail = type(self.stream_error.message) == "string" and self.stream_error.message or nil
        return self:retryOr(words[500], { kind = "http", code = 500, detail = detail })
    end
    if self.finish == "content_filter" or self.refused then
        return self:fail(self.cfg.name .. " declined to answer this.", { kind = "refusal" })
    end
    if not (self.done or self.finish) then
        return self:fail("The answer was cut off.", { kind = "cut" })
    end
    local stop = self.finish == "length" and "max_tokens" or "end_turn"
    if stop == "max_tokens" and not self.text:find("%S") then
        return self:fail(self.cfg.name .. " ran out of room before answering.", { kind = "max_tokens" })
    end
    self.finished = true
    local info = { model = self.model_used or self.cfg.model, stop_reason = stop, ms = net_info.ms,
        first_text_ms = self.first_text_ms }
    logger.info("quiet ai:", info.model, info.ms, "ms, first text", info.first_text_ms, "ms, finish", self.finish)
    if self.opts.on_done then
        local ok, err = pcall(self.opts.on_done, self.text, info)
        if not ok then logger.warn("quiet ai: on_done failed", err) end
    end
end

function Job:start()
    if self.finished then return end
    self.attempt = self.attempt + 1
    self.text, self.pending, self.first_text_ms = "", {}, nil
    self.done, self.finish, self.stream_error, self.refused = false, nil, nil, nil
    self.sse = require("quiet_claude")._sse()
    local headers = { ["content-type"] = "application/json" }
    if self.cfg.key then headers["authorization"] = "Bearer " .. self.cfg.key end
    self.req = Net.request{
        url = endpoint(self.cfg.url), method = "POST", headers = headers, body = self.body, stream = true,
        label = "ai", timeout = 90, total_timeout = 600,
        on_chunk = function(bytes) self:onChunk(bytes) end,
        on_done = function(code, body, info) self:onDone(code, body, info) end,
        on_error = function(_, info)
            local name = self.cfg.name
            local message = ({ offline = "Couldn't reach " .. name .. ".", timeout = name .. " took too long.",
                tls = "Couldn't make a secure connection to " .. name .. ".",
                closed = "The connection to " .. name .. " dropped." })[info.kind] or "Network error."
            local i = { kind = info.kind, detail = info.detail }
            if info.kind == "offline" or info.kind == "closed" then return self:retryOr(message, i) end
            self:fail(message, i)
        end,
    }
end

function OpenAI.stream(opts)
    local cfg = Keys.ai()
    local job = setmetatable({ opts = opts, cfg = cfg or { name = "AI" }, attempt = 0, text = "" }, Job)
    job.on_event = function(name, data) job:onEvent(name, data) end
    if not cfg then
        UIManager:nextTick(function() job:fail("No AI is set up on this Kindle.", { kind = "nokey" }) end)
        return job
    end
    local body, why = OpenAI.buildRequest(opts, cfg)
    local ok, encoded = pcall(rapidjson.encode, body)
    if not body or not ok or type(encoded) ~= "string" then
        UIManager:nextTick(function() job:fail("Nothing to ask.", { kind = "request", detail = why }) end)
        return job
    end
    job.body = encoded
    job.wifi = Net.whenOnline(function()
        if not job.finished then job:start() end
    end, function()
        job:fail("Couldn't get online. Check Wi-Fi and try again.", { kind = "wifi" })
    end)
    return job
end

return OpenAI
