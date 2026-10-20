-- Library as a calm grid of covers (4 x 2, progress under each) instead of KOReader's file list with sizes and
-- separator lines; title bar keeps only the title and search.
return {
    note = "library: cover grid 4x2, progress under covers, title + search only",
    ["sqlite:settings/bookinfo_cache.sqlite3:config"] = {
        filemanager_display_mode = "mosaic_image",
        nb_cols_portrait = 4,
        nb_rows_portrait = 2,
        show_progress_in_mosaic = "Y",
        no_hint_description = "Y",
    },
    simpleui = {
        simpleui_tb_item_fm_menu = false,
        simpleui_tb_item_fm_browse = false,
        simpleui_tb_item_fm_back = false,
        simpleui_tb_item_fm_search = true,
    },
}
