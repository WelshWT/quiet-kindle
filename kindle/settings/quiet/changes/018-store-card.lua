-- Asked for: the Store row "isn't clickable" and its icon "looks like a trash can"; then: open Amazon's books straight
-- from our UI and see them listed. Home's "Kindle Store books" row becomes a card (plugin quiethome.koplugin): the
-- cart icon, how many books only Amazon's reader opens, their covers (tap one to open it) and a chevron (tap for
-- the list of all of them). It takes the old row's place under Collections; the old row is switched off.
return {
    note = "home: Kindle Store books card with covers instead of the Store row",
    simpleui = {
        simpleui_hs_module_order = {
            "currently", "collections", "quiet_store", "recent", "clock", "quote", "coverdeck", "new_books", "tbr",
            "reading_goals", "reading_stats", "quick_actions_row_000001", "quick_actions_row_000002",
            "quick_actions_row_000003", "action_list",
        },
        simpleui_hs_quiet_store_enabled = true,
        simpleui_hs_action_list_enabled = false,
    },
}
