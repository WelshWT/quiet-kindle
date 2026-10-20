-- Asked for: "default to list with thumbnails, text titles are easier to scan". The Library opens as a list (cover,
-- title, author and series, one progress line; rows drawn by patches/2-quiet-library.lua), seven books a page.
-- The cover grid is one tap away on the switch in the Library header, and the last one used is remembered.
-- File size and page-count columns stay off for anything CoverBrowser still draws itself (folders, books not yet
-- catalogued).
return {
    note = "library: list with covers by default, 7 a page, grid/list switch in the header",
    ["sqlite:settings/bookinfo_cache.sqlite3:config"] = {
        filemanager_display_mode = "list_image_meta",
        files_per_page = 7,
        hide_file_info = "Y",
        hide_page_info = "Y",
    },
}
