-- WordNet as tidy HTML for KOReader: part of speech, numbered senses, examples in italics, then what else the
-- word can be called and its opposite. dict.org's WordNet is plain text hard-wrapped at ~70 characters, which
-- KOReader would re-justify into ragged lines; KOReader runs this file only for HTML dictionaries, so the .ifo
-- next to it says sametypesequence=h (the stored text itself is unchanged).
local POS = { n = "noun", v = "verb", adj = "adjective", adv = "adverb" }

local function esc(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function words(list)
    local out, seen = {}, {}
    for w in list:gmatch("{([^}]+)}") do
        if not seen[w] then
            seen[w] = true
            out[#out + 1] = w
        end
    end
    return out
end

local function sense(text)
    local syn, ant = {}, {}
    text = text:gsub("%[syn: ([^%]]-)%]", function(list) syn = words(list) return "" end)
    text = text:gsub("%[ant: ([^%]]-)%]", function(list) ant = words(list) return "" end)
    text = text:gsub("{([^}]+)}", "%1"):gsub("%s+", " "):gsub("^%s+", ""):gsub("[%s;]+$", "")
    local def, examples, notes = text, {}, {}
    local q = text:find(';%s*"')
    if q then
        def = text:sub(1, q - 1)
        -- after the examples: who said one ("- Liam O'Flaherty"), a pointer ("See abhor"); "[also: ...]" only lists
        -- other forms of the word and isn't shown
        local rest = text:sub(q):gsub("%[also: [^%]]-%]", "")
        local function between(s)
            s = s:gsub("^[%s;,]+", ""):gsub("[%s;,]+$", "")
            if s == "" then return end
            local who = s:match("^%-%s*(.+)$")
            if who and #examples > 0 then
                examples[#examples] = examples[#examples] .. " \u{2014} " .. esc(who)
            else
                notes[#notes + 1] = esc(s)
            end
        end
        local last = 1
        for qs, ex, qe in rest:gmatch('()"([^"]+)"()') do
            between(rest:sub(last, qs - 1))
            examples[#examples + 1] = "<i>" .. esc(ex) .. "</i>"
            last = qe
        end
        between(rest:sub(last))
    end
    local html = esc(def)
    if #examples > 0 then html = html .. ': <span class="ex">' .. table.concat(examples, "; ") .. "</span>" end
    if #notes > 0 then html = html .. ' <span class="also">' .. table.concat(notes, "; ") .. "</span>" end
    if #syn > 0 then html = html .. ' <span class="also">also ' .. esc(table.concat(syn, ", ")) .. "</span>" end
    if #ant > 0 then html = html .. ' <span class="also">opposite ' .. esc(table.concat(ant, ", ")) .. "</span>" end
    return html
end

return function(definition)
    local lines = {}
    for line in (definition .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
    local items = {}
    for _, line in ipairs(lines) do
        -- The headword is repeated, unindented, before each part of speech; every definition line is indented
        -- (review C1-13: a repeat used to land at the end of the previous sense).
        if line:match("^%S") then line = "" end
        local pos, rest = line:match("^%s+(%a+)%s+%d+:%s*(.*)$")
        if not pos then pos, rest = line:match("^%s+(%a+)%s*:%s*(.*)$") end
        local numbered = line:match("^%s+%d+:%s*(.*)$")
        if pos and POS[pos] then
            items[#items + 1] = { pos = POS[pos], text = rest }
        elseif numbered then
            items[#items + 1] = { text = numbered }
        elseif #items > 0 and line:match("%S") then
            items[#items].text = items[#items].text .. " " .. line
        end
    end
    if #items == 0 then return "<p>" .. esc(definition) .. "</p>" end
    local out, open = {}, false
    for _, it in ipairs(items) do
        if it.pos then
            if open then out[#out + 1] = "</ol>" end
            out[#out + 1] = '<p class="pos">' .. it.pos .. "</p><ol>"
            open = true
        elseif not open then
            out[#out + 1] = "<ol>"
            open = true
        end
        out[#out + 1] = "<li>" .. sense(it.text) .. "</li>"
    end
    if open then out[#out + 1] = "</ol>" end
    return table.concat(out)
end
