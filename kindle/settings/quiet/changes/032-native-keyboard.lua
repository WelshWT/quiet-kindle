-- Asked for: "the keyboard/typing is really buggy, slow, and weird. please use REA to just copy the native kindle
-- keyboard behavior or just have that be our keyboard", then "not just have the same behavior but maximize
-- performance and reliability". KOReader's keyboard gives way to a copy of the Kindle's own, built from its keymap
-- and libkb (patches/2-quiet-keyboard.lua): Amazon's layout and accents, the key framed as the finger lands and typed
-- as it lifts, two-finger rollover, backspace repeat. Undo this change for KOReader's keyboard again.
return {
    note = "keyboard: the Kindle's own (layout, accents on hold, frame on touch, type on lift), not KOReader's",
    reader = {
        quiet_keyboard = true,
    },
}
