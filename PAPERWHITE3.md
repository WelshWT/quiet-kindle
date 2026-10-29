# An independent Kindle · Paperwhite 3 field guide

An offline reading setup by WelshWT, made with the help of ChatGPT and built on other people's excellent work. **Experimental edition · 29 October 2026.**

Read the [web guide](https://welshwt.github.io/quiet-kindle/) or the sections below. This fork preserves Quiet's history and credits. The `paperwhite3-experimental` branch contains our additions; it is not a verified stable release.

## Get guided help with ChatGPT or Claude

**I made this project with the help of ChatGPT. You can use ChatGPT or Claude to guide you through it too.**

1. Connect your Kindle or e-reader to your **Windows PC or Mac using a USB data cable**. Keep the reader offline while checking compatibility and preparing it.
2. Open ChatGPT or Claude on your computer and give it this webpage: **https://welshwt.github.io/quiet-kindle/**.
3. Copy the request below. Tell the assistant your exact reader model and firmware, then follow the process one step at a time.

```text
Help me follow this guide: https://welshwt.github.io/quiet-kindle/
My e-reader is connected to my Windows PC or Mac by USB.
First help me identify its exact model and firmware and check compatibility.
Explain each step simply and check the result before moving on.
Ask before changing files, installing software, deleting anything or jailbreaking.
Treat the experimental improvements as unverified and explain the recovery steps.
If my reader is a Kobo or another brand, use its supported installation guide;
do not apply the Kindle jailbreak or this Kindle-specific fork unchanged.
```

Connecting by USB does not automatically give a chat assistant access to your device. It can guide you through manual steps; direct inspection or file changes require an app with suitable local tools and your permission. If the assistant cannot open the webpage, paste the relevant guide section into the chat. Check the maintained upstream instructions together before installing anything.

## What this actually changes

The aim is a reader for your own documents: USB transfers, EPUB and PDF reading, collections, a useful Home screen and accessible settings. Amazon's operating system remains installed. We have not replaced the firmware, removed every Amazon service, installed Tailscale or enabled automatic boot into KOReader. Optional cloud AI is unnecessary for reading.

## 1. Check your device

Our device was a **Kindle Paperwhite 3, 7th generation (2015)** running **5.16.2.1.1**. We used **KOReader 2026.07.1**, **SimpleUI 2.7.5** and Quiet upstream commit `783a1c15e1917337f33c0f54517c3b75d652e3ea`.

Find the model and firmware in Kindle Settings → Device Options → Device Info. Use the [KindleModding compatibility wizard](https://kindlemodding.org/jailbreak-wizard.html) with your own details. A similar-looking Kindle can require a different method. If its recommendation differs, follow the maintained guide rather than this historical setup.

**Checkpoint:** you know your exact model, firmware and supported jailbreak route. Keep your full serial private.

## 2. Prepare before going online

Charge well above a low-battery warning; we suggest at least 50% as a conservative preparation target. Keep Airplane Mode on initially. Use a data-capable USB cable and confirm the Kindle appears as a drive on the computer.

Back up documents and KOReader settings, including `settings.reader.lua`, `settings/`, `defaults.custom.lua` if present, and book `.sdr` folders. Quiet can clear per-book font/layout overrides, so saving just the books will not preserve all reading preferences.

Read the [KindleModding preparation overview](https://kindlemodding.org/jailbreaking/) and [update-prevention instructions](https://kindlemodding.org/jailbreaking/prevent-auto-update/) before enabling Wi-Fi. The current preparation guide uses temporary filler files and a small remaining free-space allowance. Follow its exact current procedure; filling storage is temporary, not a permanent reading configuration.

**Checkpoint:** your backup is readable, the USB connection works, and the maintained update-prevention procedure is complete.

## 3. WinterBreak2

Only continue if the compatibility wizard selected this route. Use the [maintained WinterBreak2 instructions](https://kindlemodding.org/jailbreaking/WinterBreak2/) and its [official release downloads](https://github.com/KindleModding/Winterbreak2/releases). We used release **1.1.0**; a future release may change the sequence.

Download and extract the supplied archive to the Kindle's top-level storage as directed. Safely eject, connect to Wi-Fi when instructed, then open the Kindle browser. Depending on firmware, it may be labelled **Web Browser** or **Experimental Browser** in the menu. The maintained guide supplies the browser address and jailbreak action. Wait for completion; a restart alone is not proof of success.

On our device, `documents/JAILBROKEN.txt` recorded success and KPM commands subsequently worked. Turn Airplane Mode back on when the online steps are finished. Complete the official [post-jailbreak steps](https://kindlemodding.org/jailbreaking/whats-next/) before removing temporary filler files or assuming update protection is active. Do not delete arbitrary `.bin` files: identify downloaded firmware updates using that guide.

**Checkpoint:** the jailbreak reports success and its post-install tools function. Stop if either check fails.

## 4. Install and open KOReader

Use the [KindleModding post-jailbreak guide](https://kindlemodding.org/jailbreaking/whats-next/) and [KOReader Kindle installation documentation](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices). Package selection depends on firmware; do not choose an archive simply because it says Kindle.

Our modern jailbreak supplied KPM. These were entered **one at a time in the Kindle's search bar**, waiting for each operation to finish:

```text
;kpm update
;kpm install koreader
;kpm launch koreader
```

If your jailbreak does not provide KPM, use its documented installation route instead. These are Kindle search commands, not Mac Terminal commands. In this setup KOReader opened its quickstart guide. Test a document before adding interface modifications.

**Checkpoint:** KOReader opens, a permitted EPUB or PDF opens, and its reading position survives closing and reopening.

## 5. Add SimpleUI and Quiet

[SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) provides interface modules. [Quiet](https://github.com/karlosdb/quiet-kindle) builds on them. Pin [SimpleUI 2.7.5](https://github.com/doctorhetfield-cmd/simpleui.koplugin/releases/tag/2.7.5) for this setup; newer releases have not been checked against these modifications. Quiet was developed on a newer Paperwhite, so its upstream screenshots and timing measurements are not evidence of Paperwhite 3 performance.

1. Exit KOReader, then connect USB. Never edit its settings while it is running.
2. Unzip the official SimpleUI 2.7.5 release. Put its `simpleui.koplugin` folder inside `koreader/plugins/` on the Kindle.
3. Save a copy of any existing plugin before replacing it. Back up settings and `.sdr` folders as in step 2.
4. Read [Quiet's installation instructions](https://github.com/karlosdb/quiet-kindle#install). Merge the **contents** of its `kindle/` folder into the Kindle's `koreader/` folder. Do not create `koreader/kindle/`.
5. Decide whether to omit `settings/quiet/changes/011-faster-transitions.lua` before the first launch. That change disables several optional plugins, including calibre, OPDS and syncing features. Quiet also applies shared text settings and changes tap zones.
6. Safely eject, unplug and open KOReader. Its first launch applies numbered changes. If it fails, inspect `koreader/settings/quiet/log.txt` and `koreader/crash.log` after exiting and reconnecting.

No API key or Amazon account is needed for KOReader's local reading features. Keep optional cloud features unconfigured for an offline setup. A claim about account-free reading is not a guarantee about every Kindle's initial setup or jailbreak requirements.

**Mac fix:** Apple's hidden `._` companion files were being mistaken for Quiet change scripts. Our change loader ignores dot-prefixed files. The setup log subsequently showed the original numbered changes applying. This is the most directly confirmed code fix in this fork.

## 6. Build a clean document library

Copy permitted EPUB and PDF files into the Kindle's `documents/` folder over USB. A simple starting structure is `documents/Fiction/`, `documents/Non-fiction/` and `documents/Reference/`. Folder names organise storage; **collections** provide separate groupings inside the reader, where supported by your interface version.

Set KOReader's home folder to `documents/`. Our experimental profile also locks browsing to that home folder and hides hidden/unsupported entries, keeping `koreader`, `libkh` and other support folders out of the normal library view. Keep system folders in place: they support the installed tools.

KFX is not a useful input for this offline KOReader workflow. Obtain a permitted EPUB/PDF original rather than renaming a KFX extension. For your own DOCX documents, export to PDF for fixed layout or convert to EPUB with a suitable converter, then inspect headings, images and reading order. Conversion does not guarantee perfect formatting, and DRM-free files still have copyright.

For duplicates, compare file hashes for exact copies, then review title/author/edition manually. Two editions or a PDF and EPUB can be intentionally different. Do not delete by title alone.

**Checkpoint:** the Library starts in documents, opens your files and shows only the folders you chose for books. This profile's folder restriction still needs an on-device acceptance check.

## 7. Our experimental improvements

These additions are published for inspection and testing. **Do not treat them as a one-click, stable upgrade.** The branch modifies Quiet itself and includes a separate SimpleUI 2.7.5 integration file. Review [the source and test checklist](TESTING-PAPERWHITE3.md) before installation.

| Change | Intended result | Evidence / status |
| --- | --- | --- |
| Ignore hidden change files | Mac `._` files no longer abort setup | Numbered changes applied after fix |
| Change 034 | Five larger book rows per library page | Configuration applied; final layout needs visual check |
| Change 035 | Restore visible interface Settings | Needs interaction check |
| Change 036 | Documents-only library, compact widgets, Home layout | Application logged; full behaviour unverified |
| SimpleUI Recent module | Multiple unfinished books under Currently reading | Needs two-book/history test |
| Direct Exit patch and Quiet label | Tap Exit KOReader from Home/Library top bar | Needs clean exit and saved-position test |
| Independent-library flag | Suppress Quiet's Amazon catalogue and Store button | Needs offline interaction check |

The SimpleUI override is `integrations/simpleui-2.7.5/module_recent.lua`. It replaces `koreader/plugins/simpleui.koplugin/modules/module_recent.lua` only on that pinned version. Keep a copy of the original first. The Quiet files in this branch keep the same paths as upstream; merge them only while KOReader is closed. Do not copy the entire repository root onto the device.

Changing Home is not the same as removing Amazon firmware. The new Currently reading module uses reading history, so books must have been opened in KOReader; files copied over USB do not automatically count as currently reading. Clock, statistics, goals and quotes remain in the proposed layout at smaller scales.

**Before calling it done:** open two books, advance each, return Home, verify both appear with correct progress, visit Settings, try Exit KOReader, reopen and verify both positions. Repeat offline and after restarting KOReader. This acceptance pass remains pending.

## 8. Covers and troubleshooting

**Cover grid partly blank:** distinguish covers embedded in EPUBs from thumbnails already indexed by the reader. An embedded cover does not prove the library cache has loaded it. Try a single book, return to Library and allow normal indexing. Some PDFs have no dedicated cover image.

**Known unresolved issue:** our library still had gaps in indexed covers. A bulk scanner was unstable. A separately generated compressed cover cache then caused KOReader startup to fail because its frame metadata did not meet the reader's expectations. We restored the earlier native cache and disabled the bulk scanner. Restart success after that rollback has not yet been confirmed. The failed cache generator, private cache database and bulk-scan patch are excluded from this publication.

**KOReader stops opening after a modification:** stop installing more changes. Reconnect by USB after KOReader has closed, preserve the log locally, remove only the newly added patch and restore your own saved settings/plugin files. Do not delete books or factory-reset as a first response. If a generated cover cache caused the failure, restore a known-good cache saved before that experiment. Ask the upstream support community with a redacted log if necessary.

**Quiet settings disappear:** upstream layout changes can hide the normal file-manager menu. Our 035 change aims to restore an explicit Settings tab; verify it before relying on it. Deleting a once-applied change file alone does not undo its settings. Use your saved settings, or a deliberate undo change following Quiet's documented change system.

**No visible difference after restart:** inspect the numbered-change log for success/failure and check that files were copied to `koreader/`, not a nested folder. On macOS, hidden `._` files must not be loaded as Lua scripts.

**Exit is awkward:** the branch adds an Exit KOReader label and touch target for Home/Library/Stats, plus an exit action in Quiet's sheet. This remains a test candidate; confirm saved positions and normal return to the Kindle interface before treating it as solved.

## 9. Recovery and updating

Keep your known-good plugin and settings copies. Follow [Quiet's uninstall instructions](https://github.com/karlosdb/quiet-kindle#uninstall) to remove its patches/plugins and restore settings and book sidecars. Restoring `.sdr` folders can also restore older reading positions. Removing patches without restoring settings is not a complete rollback. Automatic KOReader boot, if separately enabled, needs its own reversal; we did not enable it here.

Do not update SimpleUI independently and assume a 2.7.5 override will still work. Recheck compatibility, change logs and backups before updating the stack. Download packages from maintainers, not copies bundled with books.

## Credits, licences and publishing

- [WinterBreak2 / KindleModding](https://github.com/KindleModding/Winterbreak2): jailbreak work credited by its guide to Scam.Net and Penguins184. This fork links to their releases and does not redistribute the exploit archive.
- [KOReader](https://github.com/koreader/koreader): reading engine, AGPL-3.0.
- [Quiet by karlosdb](https://github.com/karlosdb/quiet-kindle): base project, AGPL-3.0-or-later; original licence and notices remain in the fork.
- [SimpleUI by doctorhetfield-cmd](https://github.com/doctorhetfield-cmd/simpleui.koplugin/tree/2.7.5): the exact 2.7.5 source is MIT. The derived Recent module retains its [MIT notice](integrations/simpleui-2.7.5/LICENSE). Do not assume later versions use that licence.
- WelshWT: Paperwhite 3 field guide and modifications, 2026. New guide material is offered under AGPL-3.0-or-later with this fork.

This independent project is not endorsed by Amazon or the upstream developers. No proprietary firmware, Amazon fonts, personal books, private caches, keys or raw device logs are included in our additions.

Publishing a guide or open-source fork is not a blanket legal clearance for circumvention. Laws differ by jurisdiction, and licence compliance does not settle anti-circumvention or contract questions. For UK readers, review [CDPA section 296ZA](https://www.legislation.gov.uk/ukpga/1988/48/section/296ZA) and the related software/device provisions; US readers can consult [the current §1201 exemptions](https://www.copyright.gov/title37/201/37cfr201-40.html). A dedicated Kindle is not automatically covered by an exemption for all-purpose tablets. Use documents you have permission to copy/convert; see [UK copyright exceptions](https://www.gov.uk/guidance/exceptions-to-copyright). Seek qualified advice for a commercial service or exploit distribution.
