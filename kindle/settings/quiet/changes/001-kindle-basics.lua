-- Stage 1 of the redesign (docs/design.md): home layout, gestures, clock, interface font,
-- refresh behaviour and a quieter footer. Book typography comes separately, from the research.
local D = "__delete__"
local ember, ember_bold = "Amazon-Ember-Regular.ttf", "Amazon-Ember-Bold.ttf"
return {
    note = "Kindle basics: 3-tab home, Store link, no stray corner taps, 12-hour clock, Amazon Ember, Kindle-like refresh",
    reader = {
        show_bottom_menu = false,             -- top tap no longer opens the bottom panel too
        twelve_hour_clock = true,             -- as the Kindle showed it
        duration_format = "letters",          -- "14m", not "00:14"
        full_refresh_count = 20,              -- flash every 20 turns instead of 6 (e-ink guidance: 10–50)
        refresh_on_chapter_boundaries = true, -- and at each chapter start, like the Kindle
        fontmap = {
            cfont = ember, tfont = ember_bold, smalltfont = ember_bold, x_smalltfont = ember_bold,
            ffont = ember, smallffont = ember, largeffont = ember, rifont = ember, pgfont = ember, hfont = ember,
            infofont = ember, smallinfofont = ember, x_smallinfofont = ember, xx_smallinfofont = ember,
        },
        ["footer.disable_progress_bar"] = true,
        ["footer.page_progress"] = false,
        ["footer.pages_left"] = false,
        ["footer.time"] = false,
        ["footer.battery"] = false,
        ["footer.book_time_to_read"] = false,
        ["footer.chapter_time_to_read"] = true,
        ["footer.percentage"] = true,
        ["footer.all_at_once"] = true,
        ["footer.items_separator"] = "none",
        ["footer.text_font_face"] = "/usr/java/lib/fonts/Amazon-Ember-Regular.ttf",
    },
    simpleui = {
        simpleui_bar_tabs = { "homescreen", "home", "stats_calendar" },        -- Home, Library, Stats
        simpleui_hs_currently_show_book_days = false,                          -- drop "1 day of reading"
        simpleui_hs_currently_show_book_time = false,                          -- drop "3m read"
        simpleui_hs_module_order = { "currently", "collections", "action_list", "recent", "clock", "quote",
            "coverdeck", "new_books", "tbr", "reading_goals", "reading_stats", "quick_actions_row_000001",
            "quick_actions_row_000002", "quick_actions_row_000003" },
        simpleui_hs_action_list_enabled = true,
        simpleui_hs_action_list_items = { "custom_qa_1" },
        simpleui_qa_list = { "custom_qa_1" },
        simpleui_qa_custom_qa_1 = { label = "Kindle Store books", dispatcher_action = "exit" },
    },
    gestures = {
        ["gesture_reader.tap_top_left_corner"] = D,     -- was: toggle page flipping
        ["gesture_reader.tap_left_bottom_corner"] = D,  -- was: light on/off by accident
        ["gesture_fm.tap_left_bottom_corner"] = D,
    },
}
