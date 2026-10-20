-- Asked for: "lowkey I dont even think we need a title at the top for Library, it's already obvious at the bottom ...
-- we could use the extra space to make the search bar easier to click". The Library tab in the bottom bar already
-- says where you are, so SimpleUI's "Library" title goes; with it off, 2-quiet-library.lua turns search into a wide
-- field ("Search your library") in the room it leaves. Undo: a new change { undo = "026-no-library-title" }.
return {
    note = "library: no title (the Library tab says where you are); search becomes a wide field",
    simpleui = {
        simpleui_tb_item_fm_title = false,
    },
}
