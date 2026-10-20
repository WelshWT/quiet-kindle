-- Library progress as KOReader's thin bar (drawn as a pill by patches/2-quiet-soft.lua) instead of SimpleUI's
-- black pointed "2%" pentagon, which clashed with the rounded shapes.
return {
    note = "library progress: native pill bar instead of pentagon banner",
    simpleui = { simpleui_fc_progress_mode = "native" },
}
