--[[
Keys for the AI in Search & Ask, and for Jev. They live only on the Kindle, in settings/quiet/keys.lua (bin/kkeys
writes Claude's and Jev's; anyone can write the file by hand):

    return {
        anthropic = "sk-ant-…",                 -- Claude, through Anthropic's own API
        ai = {                                  -- or any OpenAI-compatible chat service instead (wins when set):
            url = "https://api.openai.com/v1",  --   the API's base address (…/chat/completions is added)
            key = "sk-…",                       --   optional for a server that needs none (a local Ollama)
            model = "<model id>",               --   the model's id, from that service's own model list
            name = "ChatGPT",                   --   what the buttons say; "AI" when left out
            book_tokens = 30000,                --   optional: how much of the book to send (default 30000)
            max_tokens = 4000,                  --   optional answer limit; OpenAI's reasoning models want
                                                --   max_completion_tokens = 4000 instead
        },
        jev = "…", jev_via = "typesafe",        -- optional: TypeSafe's Jev finds described moments by meaning
    }

All of it is optional: without an AI the ask buttons are hidden and search stays on the Kindle, except that a Jev key,
if there is one, still finds described moments ("the scene at the ball"): Jev gets those words and the nearby book
text. Missing file or missing entries just mean "not set up" (nil). Keys are never logged, not even their length.
]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Keys = {}

local cache, cache_mtime

local function path()
    return DataStorage:getSettingsDir() .. "/quiet/keys.lua"
end

local function nonEmpty(v)
    if type(v) ~= "string" then return nil end
    v = v:match("^%s*(.-)%s*$")
    return v ~= "" and v or nil
end

-- The whole file as a table ({} when missing or unreadable), re-read when it changes on disk.
function Keys.all()
    local p = path()
    local mtime = lfs.attributes(p, "modification")
    if not mtime then
        cache, cache_mtime = {}, nil
        return cache
    end
    if cache and cache_mtime == mtime then return cache end
    local ok, t = pcall(dofile, p)
    cache = (ok and type(t) == "table") and t or {}
    cache_mtime = mtime
    return cache
end

function Keys.anthropic()
    return nonEmpty(Keys.all().anthropic)
end

-- The OpenAI-compatible service, or nil: url and model are needed, the rest is optional.
function Keys.ai()
    local t = Keys.all().ai
    if type(t) ~= "table" then return nil end
    local url, model = nonEmpty(t.url), nonEmpty(t.model)
    if not (url and model) then return nil end
    return {
        url = url, model = model, key = nonEmpty(t.key), name = nonEmpty(t.name) or "AI",
        book_tokens = tonumber(t.book_tokens), max_tokens = tonumber(t.max_tokens),
        max_completion_tokens = tonumber(t.max_completion_tokens),
    }
end

-- The Jev key and how to reach it ("typesafe" unless the file says otherwise).
function Keys.jev()
    local t = Keys.all()
    local key = nonEmpty(t.jev)
    if not key then return nil end
    return key, nonEmpty(t.jev_via) or "typesafe"
end

return Keys
