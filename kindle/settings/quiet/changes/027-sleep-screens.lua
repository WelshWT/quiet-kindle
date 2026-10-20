-- Asked for: "can we have some better options for sleeping screen? rn it just says sleeping". Quiet's sleep screens
-- (quiet_sleep.lua, through patches/2-quiet-sleep.lua) replace KOReader's "Sleeping" box: the 3D block QUIET cover to
-- start with, light, Shuffle off; chosen in the Sleep screen sheet (the Sleep screen row of the pull-down sheet).
-- KOReader's own message is turned off too, so if Quiet's sleep screen ever can't be made, the screen stays as it was
-- instead of showing the box.
return {
    note = "sleep: Quiet's sleep screens (3D block to start), no more Sleeping box",
    reader = {
        quiet_sleep = "quiet-3",
        quiet_sleep_dark = false,
        quiet_sleep_shuffle = false,
        screensaver_show_message = false,
    },
}
