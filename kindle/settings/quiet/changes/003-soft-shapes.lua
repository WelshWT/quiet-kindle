-- Softer, calmer home: floating pill tab bar (no straight line across the screen), rounded line icons,
-- rounded progress bars (shapes in patches/2-quiet-soft.lua). Research: preference for curved contours
-- (Bar & Neta 2006; Chuquichambi et al. 2022 meta-analysis), Material 3 shape scale.
local I = "/mnt/us/koreader/icons/quiet/"
return {
    note = "soft shapes: pill tab bar, rounded icons",
    simpleui = {
        simpleui_bar_style = "framed",
        simpleui_action_homescreen_icon = I .. "home.svg",
        simpleui_action_home_icon = I .. "library.svg",
        simpleui_action_stats_calendar_icon = I .. "stats.svg",
        ["simpleui_qa_custom_qa_1.icon"] = I .. "store.svg",
    },
}
