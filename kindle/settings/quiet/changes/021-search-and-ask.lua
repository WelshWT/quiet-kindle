-- Asked for: the Claude plugin is "clunky… outdated", search should be "smarter and simpler", ask about the current
-- page without highlighting, never past your position unless a switch says so. Search & Ask (quiet_ask.lua and
-- friends in quiet.koplugin) now does all of that from the toolbar's Search, the selection bar's Ask Claude and the
-- More sheet, so the old assistant plugin goes: no more "AI" buttons on the dictionary card, no second set of
-- Claude dialogs. Its files stay on the Kindle; undo brings it back.
return {
    note = "search & ask: our own sheet replaces the old Claude (assistant) plugin",
    reader = {
        ["plugins_disabled.assistant"] = true,
    },
}
