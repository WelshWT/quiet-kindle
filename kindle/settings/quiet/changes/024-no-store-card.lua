-- Asked for: "once we have the books show in the library, we dont need this 'kindle store books' thing on the
-- homescreen. it reminds me of amazon bloat. u just want to access books from ur library. but there should still be
-- an intuitive way to go back to the amazon OS". Amazon's books are in the Library now, among the others
-- (patches/2-quiet-library.lua), and its header has a Store button for Amazon's store and home; so the Home card
-- goes. The old Store row stays off. The 266 px the card and its gap leave (measured 2026-10-19: 1379 px for modules,
-- 1113 used without it) go to the book in hand: its cover at 140% (219 px taller, Home's own "Cover size" setting),
-- so Home ends with the usual 49 px margin instead of an empty band.
return {
    note = "home: no Kindle Store card (Amazon's books are in the Library, Store button in its header)",
    simpleui = {
        simpleui_hs_module_order = {
            "currently", "collections", "recent", "clock", "quote", "coverdeck", "new_books", "tbr", "reading_goals",
            "reading_stats", "quick_actions_row_000001", "quick_actions_row_000002", "quick_actions_row_000003",
            "action_list",
        },
        simpleui_hs_quiet_store_enabled = false,
        simpleui_hs_currently_thumb_scale = 140,
        simpleui_hs_action_list_enabled = false,
    },
}
