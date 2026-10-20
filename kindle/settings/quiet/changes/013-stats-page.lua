-- Asked for: "improve the stats page to be more interesting and have visuals/graphs … a streak counter", research
-- what's meaningful and fun. Design: "Stats" in docs/design.md. The Stats tab now opens a
-- SimpleUI custom screen holding only the Quiet stats page (plugin quietstats.koplugin) instead of the
-- three-page Reading Insights pop-up. Streak starts fresh.
local PFX = "simpleui_cs_qstats_"
local ICON = "/mnt/us/koreader/icons/quiet/stats.svg"
return {
    note = "stats: full Stats page (streak, this week, current book, reading days, this year) behind the Stats tab",
    simpleui = {
        simpleui_custom_screens = {
            { id = "cs_qstats", name = "Stats", icon = ICON, pfx = PFX, layout_key = "simpleui_layout_cs_qstats" },
        },
        simpleui_layout_cs_qstats = { pages = { { modules = { "quiet_stats" } } } },
        -- a new SimpleUI screen starts with these modules forced off; nothing else on this one
        [PFX .. "clock_enabled"] = false,
        [PFX .. "clock_date"] = false,
        [PFX .. "clock_battery"] = false,
        [PFX .. "currently_enabled"] = false,
        [PFX .. "reading_goals_enabled"] = false,
        [PFX .. "overflow_warn"] = false,
        [PFX .. "settings_on_hold"] = false,
        simpleui_bar_tabs = { "homescreen", "home", "open_custom_screen:cs_qstats" },
        ["simpleui_action_open_custom_screen:cs_qstats_icon"] = ICON,
    },
}
