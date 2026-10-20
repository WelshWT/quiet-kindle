-- Quiet: on the way out of KOReader (to Amazon's screens, or a restart), Amazon's status bar and its own automatic
-- light, which patches/quiet-amazon-guard.sh stops while KOReader runs (run by 2-quiet-light.lua at the start): given
-- back if this KOReader owns them, checked and marked, by the guard and only there, under its lock (this runs before
-- the settings are saved). If that didn't all take, the guard's crash watcher tries again once KOReader is gone.
local L = package.loaded["quiet_autolight"]
if L and L.giveBack then pcall(L.giveBack) end
