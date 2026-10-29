# Paperwhite 3 acceptance status

Experimental branch. Recorded 29 October 2026. No stable release is claimed.

## Recorded evidence

- WinterBreak2 reported success; KPM installed and launched KOReader.
- KOReader opened its quickstart and the user opened books.
- Quiet's loader applied the original numbered changes after hidden macOS files were excluded.
- Dashboard change 036 was recorded as applied in the settings log.
- Generated cover-cache failure was diagnosed; an earlier native cache was restored and the bulk scanner disabled. Successful opening after this rollback is not yet confirmed.

## Required checks on the actual device

- [ ] Confirm KOReader starts after the cache rollback.
- [ ] Open an EPUB and PDF; advance pages, close and reopen each.
- [ ] Open two unfinished books, return Home and confirm both appear with their own progress.
- [ ] Mark one finished; confirm the Currently reading list excludes it.
- [ ] Confirm no system folders or Amazon Store entries appear in normal Library browsing.
- [ ] Verify five readable rows and cover sizing on the 6-inch screen.
- [ ] Open Settings from the visible tab; change and restore one harmless preference.
- [ ] Tap Exit KOReader from Home, Library and Stats; verify normal return and saved reading positions.
- [ ] Check direct Exit does not intercept adjacent top-bar controls.
- [ ] Repeat launch and reading-position checks offline and after restart.
- [ ] Confirm normal one-book cover indexing without generated caches or bulk scanning.

## Installation scope

Quiet files mirror the Kindle's `koreader/` directory. The separate `integrations/simpleui-2.7.5/module_recent.lua` replaces that pinned plugin's `modules/module_recent.lua`. Back up originals and settings first; close KOReader before copying. Read PAPERWHITE3.md before applying anything. No unattended installer is included.

## Excluded experiments

No externally generated cover database, bulk-cover scanner, commercial book file, book manifest, private log or host-specific transfer script is included. No Amazon firmware removal, Tailscale installation or automatic boot claim is made.
