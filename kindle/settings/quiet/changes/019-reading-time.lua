-- Asked for: "add % done and minutes/hours read so far on the currently reading module (and make it a smart
-- algorithm that doesn't count the idle time sitting on a page until timeout)". Home's card: a plain bar, then
-- "5% done", then "42 min read · 5 h 14 min left". SimpleUI draws them; the numbers are ours
-- (quiet_readtime.lua through patches/2-quiet-currently.lua), the same as the footer, the Library and Stats.
return {
    note = "home: % done, honest time read and time left to the end of the story on Currently Reading",
    simpleui = {
        simpleui_hs_currently_bar_style = "simple",
        simpleui_hs_currently_show_percent = true,
        simpleui_hs_currently_show_book_time = true,
        simpleui_hs_currently_show_book_remaining = true,
        simpleui_hs_currently_stats_style = "compact",
    },
}
