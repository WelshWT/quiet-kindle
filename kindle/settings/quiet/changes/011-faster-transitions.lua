-- Speed (asked for: "as fast and smooth as possible"): plugins this Kindle can't or doesn't use are switched off.
-- KOReader starts every plugin again each time a book or the home screen opens; measured on this Kindle,
-- External keyboard alone re-scanned all input devices for 160-195 ms of each ~0.5 s screen build.
-- The rest cost little per screen but load at every start and fill the menus. Any of them comes back in KOReader's
-- Plugin management (All KOReader settings > Tools > More tools), or with a change that sets it to "__delete__".
return {
    note = "speed: switch off unused plugins (external keyboard scan cost ~180 ms per book open / home)",
    reader = {
        ["plugins_disabled.externalkeyboard"] = true, -- no USB host or keyboard on a Kindle
        ["plugins_disabled.httpinspector"] = true,    -- developer tool
        ["plugins_disabled.terminal"] = true,
        ["plugins_disabled.texteditor"] = true,
        ["plugins_disabled.japanese"] = true,
        ["plugins_disabled.wallabag"] = true,
        ["plugins_disabled.newsdownloader"] = true,
        ["plugins_disabled.opds"] = true,
        ["plugins_disabled.calibre"] = true,          -- turn back on if you send books from calibre
        ["plugins_disabled.cloudstorage"] = true,
        ["plugins_disabled.kosync"] = true,
        ["plugins_disabled.perceptionexpander"] = true,
        ["plugins_disabled.autoturn"] = true,
        ["plugins_disabled.qrclipboard"] = true,
        ["plugins_disabled.systemstat"] = true,
        ["plugins_disabled.batterystat"] = true,
        ["plugins_disabled.movetoarchive"] = true,
        ["plugins_disabled.archiveviewer"] = true,
        ["plugins_disabled.docsettingtweak"] = true,
        ["plugins_disabled.bookshortcuts"] = true,
    },
}
