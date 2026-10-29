-- Derived from SimpleUI 2.7.5, Copyright (c) 2026 doctorhetfield-cmd.
-- MIT licensed; see LICENSE in this directory. Modified by WelshWT, 2026:
-- show multiple unfinished history entries as Currently reading.
-- Multiple unfinished, actually opened KOReader books, with cover/progress.
local Grid = require("engines/sui_book_grid")
local BookList = require("ui/widget/booklist")
return Grid.makeModule{
    id = "recent", name = "Currently reading", label = "Currently reading",
    default_on = true, is_book_mod = true, max_items = 3, paged = true,
    getFileList = function(ctx) return ctx.recent_fps end,
    filterItem = function(fp)
        return fp and not fp:find("/koreader/help/", 1, true)
            and BookList.getBookStatus(fp) ~= "complete"
    end,
    progress_style = { default = "bar_text" },
}
