-- Calmer library grid: no ".." parent tile, no black "New" ribbons, no extra progress squares (KOReader's own
-- pill-shaped progress bar under each cover remains). The collection star is hidden in patches/2-quiet-soft.lua.
return {
    note = "library: lock home folder, no New ribbons, no duplicate progress overlay",
    reader = { lock_home_folder = true },
    simpleui = {
        simpleui_fc_new_mode = "none",
        simpleui_fc_overlay_progress = false,
    },
}
