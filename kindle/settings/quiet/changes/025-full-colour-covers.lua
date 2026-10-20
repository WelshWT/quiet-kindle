-- Asked for: "a lot of the book cover thumbnails look weirdly unsaturated" in the Library's grid. SimpleUI fades the
-- covers of finished books by half (its "fade finished books", on by default); it shows as soon as books are
-- marked finished. Covers stay at full strength now; the list view still says
-- "Finished · <month>".
return {
    note = "library: finished books' covers no longer faded in the grid",
    simpleui = {
        simpleui_fc_fade_finished = false,
    },
}
