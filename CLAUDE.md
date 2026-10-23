# Notes for AI agents

- A Kindle that doesn't have Quiet yet: follow AGENTS.md, the install guide. These notes are for working on one
  that does.
- Read README.md first. Never edit settings files on the Kindle directly while KOReader runs: it rewrites
  them on exit. Add a change file and `bin/kpush` instead.
- Never `kill -9` KOReader while a book is open (`bin/kcmd status` tells you); it loses the reading position.
  `bin/kpush --hard` is only for when the bridge isn't running. Frozen, and the bridge doesn't answer? `bin/kstack`
  shows where KOReader is stuck, without stopping it.
- One change file per request, named for what the person asked ("031-narrower-margins.lua"), with a `note`.
  Commit it with the request in the message. To undo, add `{ undo = "<id>" }` as a new change.
- After every push, look at the screenshot before saying it's done.
- On the device: real-time controls (light, warmth, Wi-Fi) and the Kindle's own Aa set (text size, looks, font,
  margins, spacing, alignment: as many as the native Kindle reader has, not the really nitty-gritty ones). Every
  finer setting is managed here, on request. Design rationale lives in docs/design.md.
- Keys (`settings/quiet/keys.lua` on the Kindle) never go in this repo, a commit, a log or your output.
