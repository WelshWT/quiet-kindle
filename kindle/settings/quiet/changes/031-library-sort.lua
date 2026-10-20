-- Asked for: "a sort by menu on the library page so I can sort by date added, alphabetical, etc". The Library header
-- gets a Sort button with five orders (patches/2-quiet-library.lua): Recent, Date added, Title, Author, Series. This
-- starts the Library on Title, the A to Z order it had (KOReader's file-name order), read one way only.
return {
    note = "library: a Sort button (Recent, Date added, Title, Author, Series); starts on Title, A to Z",
    reader = {
        collate = "quiet_title",
        reverse_collate = "__delete__",
    },
}
