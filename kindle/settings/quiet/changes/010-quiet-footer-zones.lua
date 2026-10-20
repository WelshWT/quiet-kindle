-- Footer for the Quiet plugin: time left in chapter on the left, percent on the right (the plugin supplies the
-- words), nothing else. Page-turn zones as on the Kindle: a narrow left strip (20%) goes back, the rest forward.
return {
    note = "footer: chapter time + filler + percent; tap zones back 20% / forward 80%",
    reader = {
        ["footer.order"] = { "chapter_time_to_read", "dynamic_filler", "percentage" },
        ["footer.dynamic_filler"] = true,
        ["footer.chapter_time_to_read"] = true,
        ["footer.percentage"] = true,
        ["footer.all_at_once"] = true,
        ["footer.items_separator"] = "none",
        ["footer.lock_tap"] = true,
    },
    ["file:defaults.custom.lua"] = {
        DTAP_ZONE_BACKWARD = { x = 0, y = 0, w = 0.2, h = 1 },
        DTAP_ZONE_FORWARD = { x = 0.2, y = 0, w = 0.8, h = 1 },
    },
}
