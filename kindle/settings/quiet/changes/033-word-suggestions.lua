-- Asked for: "Can you add lightweight but accurate autocorrect here? Does Amazon have that already? Can you just take
-- that?", then "Or at least like word suggestions in the top row". Amazon's (the Kindle's XT9 engine) was tried first
-- and dropped ("barely functional": it sees only the letters typed); a Gboard-style decoder on AOSP's word list does
-- it now, in a process of its own (patches/quiet-decoder.lua, patches/quiet-words.lua). A row of word suggestions
-- above the keys, and corrections of clear slips on space, which one backspace takes back
-- (patches/2-quiet-keyboard.lua). Undo this change to turn both off.
return {
    note = "keyboard: word suggestions above the keys, careful autocorrect (one backspace undoes it)",
    reader = {
        quiet_keyboard_suggest = true,
        quiet_keyboard_autocorrect = true,
    },
}
