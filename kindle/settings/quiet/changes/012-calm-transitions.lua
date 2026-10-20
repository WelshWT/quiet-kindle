-- Speed and calm (asked for: "as fast and smooth as possible"): going Home from a book now takes about half a
-- second, so SimpleUI's "Closing book…" box only flashed up and away again. The home screen is the feedback.
return {
    note = "home: no 'Closing book…' box when leaving a book",
    simpleui = {
        simpleui_hs_closing_notice_mode = "never",
    },
}
