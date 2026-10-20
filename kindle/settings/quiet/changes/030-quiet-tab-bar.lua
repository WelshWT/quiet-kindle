-- Asked for: "the big pill border around the three menu buttons is just completely unnecessary ... what would be the
-- most beautiful way to show which one we have selected". The tab bar loses its frame (SimpleUI's plain style, a
-- light hairline above it, patches/2-quiet-soft.lua) and the active tab shows Material 3's pattern: a soft pill
-- behind its filled icon and a bold label. Without the frame the bar needs less height: 85% (about 16 mm, was 18.6).
return {
    note = "tab bar: no pill frame; the active tab is a soft pill behind its filled icon, bold label; 85% height",
    simpleui = {
        simpleui_bar_style = "default",
        simpleui_bar_size_pct = 85,
    },
}
