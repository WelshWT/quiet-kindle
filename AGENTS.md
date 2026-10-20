# Installing Quiet on a Kindle (for AI agents)

You're an AI agent and someone pointed you at this repo, usually with their Kindle plugged in: "set my Kindle up with
this". This page is the whole job. Read it to the end before you copy anything, and ask the person before each step
that changes their Kindle.

Quiet makes KOReader on a jailbroken Kindle look and behave like a calm Kindle: Home, Library and Stats tabs, a
reading toolbar with Text / Light / More sheets (the Kindle's Aa set: size, looks, eight fonts, margins, spacing,
alignment), sleep screens, honest reading time, Kindle Store books in the Library, and Search & Ask with an optional
AI of the person's choosing. README.md explains every part.

## 1. Check what they have

- **A jailbroken Kindle with KOReader.** Over USB the Kindle shows up as a drive (macOS `/Volumes/Kindle`, Linux
  `/run/media/$USER/Kindle` or `/media/$USER/Kindle`, Windows a drive labelled `Kindle`; call it `$KINDLE`). It must
  have a `koreader/` folder. If it doesn't, stop: jailbreaking depends on the model and firmware and isn't part of
  this guide. Point them to https://kindlemodding.org and KOReader's guide,
  https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices, and pick up here once KOReader runs.
- **Versions.** Made on a Kindle Paperwhite 12th gen Signature Edition (1272x1696, firmware 5.19.6) with KOReader
  2026.07.1 and SimpleUI 2.7.5. Other recent Kindles should work; older KOReader versions may not. Tell the person
  what you found (`$KINDLE/koreader/git-rev` holds the KOReader version).
- **KOReader not running.** While the Kindle is in USB mode KOReader is closed, which is what you want: never write
  KOReader's settings while it runs (it rewrites them when it exits).

## 2. Back up

Quiet changes settings in three places, so back up all three to the person's computer and tell them where:

- `$KINDLE/koreader/settings.reader.lua`, the folder `$KINDLE/koreader/settings/`, and
  `$KINDLE/koreader/defaults.custom.lua` if it's there (Quiet's tap zones go in it);
- every book's own settings: the `.sdr` folders next to the books under `$KINDLE/documents/` (on its first start Quiet
  clears per-book font and layout overrides there, and from then on keeps one set for every book). Only those
  folders, not the books:
  `rsync -a --prune-empty-dirs --include='*/' --include='*.sdr/**' --exclude='*' "$KINDLE/documents/" "<backup>/documents/"`

Every change Quiet makes can be undone, but this backup is the simple way all the way back.

## 3. Install SimpleUI 2.7.5

Quiet builds on SimpleUI (MIT, by Doctor Hetfield). Download
https://github.com/doctorhetfield-cmd/simpleui.koplugin/releases/download/2.7.5/simpleui.koplugin.zip, unzip it, and
put the `simpleui.koplugin` folder into `$KINDLE/koreader/plugins/`. If a `simpleui.koplugin` is already there, ask
before replacing it.

## 4. Copy Quiet

`kindle/` in this repo mirrors `koreader/` on the Kindle. Copy its contents into `$KINDLE/koreader/`, merging folders
and replacing files of the same name:

```sh
rsync -rt kindle/ "$KINDLE/koreader/"
```

(Without rsync: copy the folders over by hand, merging.) The fonts it uses, Bookerly and Amazon Ember, are the
Kindle's own; nothing to install.

Tell the person, before copying, what Quiet changes beyond looks: one text layout for every book (per-book font and
layout overrides are cleared), the Kindle's tap zones, and change `011`, which switches off KOReader plugins Quiet
doesn't use (calibre, OPDS, progress sync, Wallabag, News downloader, cloud storage and others) to make screens faster.
If they use any of those, they can turn it back on afterwards in All KOReader settings > Tools > More tools > Plugin
management; or leave `settings/quiet/changes/011-faster-transitions.lua` out of the copy.

Optional: the dictionaries Quiet sets up (WordNet first, then GCIDE) aren't in the repo. README.md, under
`kindle/data/dict/`, has the two download links and where to unpack them; without them KOReader's own dictionaries
are used.

## 5. An AI for Search & Ask (optional)

Without one, everything works: search stays offline and the ask buttons are hidden. To add one, ask the person which
service they use and for a key, then write `$KINDLE/koreader/settings/quiet/keys.lua`, one of:

```lua
-- Claude, through Anthropic's API
return { anthropic = "sk-ant-..." }
```

```lua
-- any OpenAI-compatible chat API: OpenAI (https://api.openai.com/v1), OpenRouter (https://openrouter.ai/api/v1),
-- Groq (https://api.groq.com/openai/v1), Gemini's OpenAI endpoint, Mistral, or a local Ollama / LM Studio
-- (http://<that computer's address>:11434/v1, no key)
return { ai = { url = "https://api.openai.com/v1", key = "sk-...", model = "<a model id from that service>",
                name = "ChatGPT", book_tokens = 30000 } }
```

`name` is what the buttons say ("Ask ChatGPT"). `book_tokens` is how much of the book is sent with a question
(30000 by default): lower it for a small local model, raise it for a model with a big context window. Take the model id
from the service's own model list, don't guess one. The full format is at the top of
`kindle/plugins/quiet.koplugin/quiet_keys.lua`.

A Jev key (`jev = "..."`, TypeSafe's Jev) is a separate option: it finds described moments ("the scene at the ball")
by meaning, even without an AI, and gets those words and the nearby book text.

Keys stay on the Kindle: write the key into that file and nowhere else. Never print it, log it, commit it or put it in
this repo. If the person would rather type it themselves, show them the file's shape and let them.

## 6. Start it

Eject the Kindle safely, unplug it, and start KOReader the way it's started there (usually KUAL > KOReader). The first
start applies Quiet's settings changes (`settings/quiet/changes/`, each once, in name order) and takes a few seconds
longer; then KOReader opens on Home with Home / Library / Stats at the bottom.

Check with the person: Home shows the tabs; opening a book shows it in Bookerly; a tap on the top band brings the
toolbar; Aa on the toolbar opens the Text sheet. If something's off, `$KINDLE/koreader/settings/quiet/log.txt` says
for each change whether it applied or why it failed (a failed one is tried again next start), and
`$KINDLE/koreader/crash.log` is KOReader's own log.

## Optional extras (need SSH to the Kindle)

- `bin/` has tools to work on the Kindle over Wi-Fi (push updates, screenshots, taps, commands); they expect `ssh
  kindle` to reach it, through KOReader's SSH server or USBNetwork. README.md, "Commands".
- `bin/kboot on` makes the Kindle boot straight into KOReader (an upstart job; root on the Kindle).
- Updating later: pull this repo and copy `kindle/` again the same way. Changes already applied aren't applied twice,
  and settings the person changed on the Kindle stay theirs.

## Undo

With the Kindle on USB (KOReader closed), delete from `$KINDLE/koreader/`: `patches/1-quiet-changes.lua`, every
`patches/2-quiet-*.lua`, `patches/8-quiet-exit.lua`, `patches/quiet-amazon-guard.sh`, the plugins `quiet.koplugin`,
`quiethome.koplugin` and `quietstats.koplugin` (and `simpleui.koplugin` if they don't want it). Then put back all of
the backup from step 2: `settings.reader.lua`, `settings/`, `defaults.custom.lua` (or delete Quiet's if there was none
before), and the `.sdr` folders into `documents/` (`rsync -a "<backup>/documents/" "$KINDLE/documents/"`). To take back
a single setting instead, see "How a change gets to the Kindle" in README.md.

## After installing

To keep working on the installed Kindle (new settings, fixes), follow CLAUDE.md: changes go in as new files under
`kindle/settings/quiet/changes/`, never as edits to the Kindle's settings while KOReader runs.
