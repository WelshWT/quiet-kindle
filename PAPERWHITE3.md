# Giving an older Kindle a more independent reading life

An offline reading setup by WelshWT, made with the help of ChatGPT and built on other people's excellent work. **Experimental project · article updated 11 November 2026.**

This is the story and practical guide behind [my independent Kindle project](https://welshwt.github.io/quiet-kindle/): an older reader, a different interface and a library of my own documents. The [published fork](https://github.com/WelshWT/quiet-kindle/tree/paperwhite3-experimental) preserves Quiet's history and credits. Its additions remain experimental.

## Get guided help with ChatGPT or Claude

**I made this project with the help of ChatGPT. You can use ChatGPT or Claude to guide you through it too.**

Start by connecting your Kindle or e-reader to a **Windows PC or Mac with a USB data cable**. Keep the reader offline while you check compatibility and prepare it. Open ChatGPT or Claude on the computer, share [this article](https://welshwt.github.io/quiet-kindle/) and ask it to guide you through the process for your exact model and firmware.

You can copy the request below into your chat. Work through one stage at a time, checking the result before continuing.

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

## A reader built around my books

The starting point was simple: I wanted to upload my own documents, organise them in a way that made sense to me and read without needing an Amazon account for everyday offline use. A library full of support folders, a Home screen that missed the books I was reading and an awkward route to exit the reader all got in the way.

The project brings together [KOReader](https://github.com/koreader/koreader), [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) and [Quiet](https://github.com/karlosdb/quiet-kindle), with experimental changes for this older Paperwhite. The aim is straightforward USB transfers, EPUB and PDF reading, collections, a useful Home screen and accessible settings.

Amazon's operating system remains underneath. This setup has not replaced the firmware, removed every Amazon service, installed Tailscale or enabled automatic boot into KOReader. Optional cloud AI is unnecessary for reading.

## Start with the exact model and firmware

Our device was a **Kindle Paperwhite 3, 7th generation (2015)** running **5.16.2.1.1**. We used **KOReader 2026.07.1**, **SimpleUI 2.7.5** and Quiet upstream commit `783a1c15e1917337f33c0f54517c3b75d652e3ea`.

Find the model and firmware in Kindle Settings → Device Options → Device Info. Use the [KindleModding compatibility wizard](https://kindlemodding.org/jailbreak-wizard.html) with your own details. A similar-looking Kindle can require a different method. If its recommendation differs, follow the maintained guide rather than this historical setup.

Before continuing, confirm the exact model, firmware and supported jailbreak route. Keep your full serial private.

## Prepare the reader before connecting to Wi-Fi

Charge well above a low-battery warning; we suggest at least 50% as a conservative preparation target. Keep Airplane Mode on initially. Use a data-capable USB cable and confirm the Kindle appears as a drive on the computer.

Back up documents and KOReader settings, including `settings.reader.lua`, `settings/`, `defaults.custom.lua` if present, and book `.sdr` folders. Quiet can clear per-book font/layout overrides, so saving just the books will not preserve all reading preferences.

Read the [KindleModding preparation overview](https://kindlemodding.org/jailbreaking/) and [update-prevention instructions](https://kindlemodding.org/jailbreaking/prevent-auto-update/) before enabling Wi-Fi. The current preparation guide uses temporary filler files and a small remaining free-space allowance. Follow its exact current procedure; filling storage is temporary, not a permanent reading configuration.

Continue once the backup is readable, the USB connection works and the maintained update-prevention procedure is complete.

## The WinterBreak2 stage

Only continue if the compatibility wizard selected this route. Use the [maintained WinterBreak2 instructions](https://kindlemodding.org/jailbreaking/WinterBreak2/) and its [official release downloads](https://github.com/KindleModding/Winterbreak2/releases). We used release **1.1.0**; a future release may change the sequence.

Download and extract the supplied archive to the Kindle's top-level storage as directed. Safely eject, connect to Wi-Fi when instructed, then open the Kindle browser. Depending on firmware, it may be labelled **Web Browser** or **Experimental Browser** in the menu. The maintained guide supplies the browser address and jailbreak action. Wait for completion; a restart alone is not proof of success.

On our device, `documents/JAILBROKEN.txt` recorded success and KPM commands subsequently worked. Turn Airplane Mode back on when the online steps are finished. Complete the official [post-jailbreak steps](https://kindlemodding.org/jailbreaking/whats-next/) before removing temporary filler files or assuming update protection is active. Do not delete arbitrary `.bin` files: identify downloaded firmware updates using that guide.

The useful confirmation is both a successful jailbreak report and working post-install tools. Stop if either check fails.

## Moving into KOReader

Use the [KindleModding post-jailbreak guide](https://kindlemodding.org/jailbreaking/whats-next/) and [KOReader Kindle installation documentation](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices). Package selection depends on firmware; do not choose an archive simply because it says Kindle.

Our modern jailbreak supplied KPM. These were entered **one at a time in the Kindle's search bar**, waiting for each operation to finish:

```text
;kpm update
;kpm install koreader
;kpm launch koreader
```

If your jailbreak does not provide KPM, use its documented installation route instead. These are Kindle search commands, not Mac Terminal commands. In this setup KOReader opened its quickstart guide. Test a document before adding interface modifications.

Before adding more software, open a permitted EPUB or PDF, close it and reopen it. Confirm that KOReader starts normally and preserves the reading position.

## Giving the reader a calmer interface

[SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) provides interface modules. [Quiet](https://github.com/karlosdb/quiet-kindle) builds on them. Pin [SimpleUI 2.7.5](https://github.com/doctorhetfield-cmd/simpleui.koplugin/releases/tag/2.7.5) for this setup; newer releases have not been checked against these modifications. Quiet was developed on a newer Paperwhite, so its upstream screenshots and timing measurements are not evidence of Paperwhite 3 performance.

Close KOReader before connecting the Kindle by USB. Unzip the official [SimpleUI 2.7.5 release](https://github.com/doctorhetfield-cmd/simpleui.koplugin/releases/tag/2.7.5) and place its `simpleui.koplugin` folder inside `koreader/plugins/`. Save a copy of any existing plugin first, along with the settings and book sidecars described earlier. Settings must not be edited while KOReader is running.

Next, follow [Quiet's installation instructions](https://github.com/karlosdb/quiet-kindle#install). Its `kindle/` folder mirrors the reader's `koreader/` folder: merge the contents into `koreader/`, rather than creating a nested `koreader/kindle/` folder.

Quiet changes more than appearance. It applies shared text settings, changes tap zones and, through `settings/quiet/changes/011-faster-transitions.lua`, disables several optional plugins, including calibre, OPDS and syncing features. If you need those features, decide whether to leave that change out before the first launch.

Safely eject the device, unplug it and start KOReader. The first launch applies Quiet's numbered changes. If it fails, close KOReader and reconnect by USB before inspecting `koreader/settings/quiet/log.txt` and `koreader/crash.log`.

No API key or Amazon account is needed for KOReader's local reading features. Keep optional cloud features unconfigured for an offline setup. A claim about account-free reading is not a guarantee about every Kindle's initial setup or jailbreak requirements.

One practical fix came from the Mac: Apple's hidden `._` companion files were being mistaken for Quiet change scripts. Our change loader ignores dot-prefixed files. The setup log subsequently showed the original numbered changes applying. This is the most directly confirmed code fix in this fork.

## Making the library about the books

Copy permitted EPUB and PDF files into the Kindle's `documents/` folder over USB. A simple starting structure is `documents/Fiction/`, `documents/Non-fiction/` and `documents/Reference/`. Folder names organise storage; **collections** provide separate groupings inside the reader, where supported by your interface version.

Set KOReader's home folder to `documents/`. Our experimental profile also locks browsing to that home folder and hides hidden/unsupported entries, keeping `koreader`, `libkh` and other support folders out of the normal library view. Keep system folders in place: they support the installed tools.

KFX is not a useful input for this offline KOReader workflow. Obtain a permitted EPUB/PDF original rather than renaming a KFX extension. For your own DOCX documents, export to PDF for fixed layout or convert to EPUB with a suitable converter, then inspect headings, images and reading order. Conversion does not guarantee perfect formatting, and DRM-free files still have copyright.

For duplicates, compare file hashes for exact copies, then review title/author/edition manually. Two editions or a PDF and EPUB can be intentionally different. Do not delete by title alone.

The intended result is a Library that starts in documents, opens your files and shows the folders you chose for books. This profile's folder restriction still needs an on-device acceptance check.

## The improvements in this fork

These additions are published for inspection and testing. **Do not treat them as a one-click, stable upgrade.** The branch modifies Quiet itself and includes a separate SimpleUI 2.7.5 integration file. Review [the source and test checklist](TESTING-PAPERWHITE3.md) before installation.

The most directly confirmed fix concerns hidden macOS files. Ignoring dot-prefixed change files allowed Quiet's numbered setup changes to apply successfully.

The remaining work targets everyday usability. Change 034 configures five larger book rows per Library page; change 035 aims to restore visible interface settings. Change 036 brings together a documents-only library and a more compact Home layout. Its application was logged, but the final screen and interactions still need checking on the device.

A separate SimpleUI module aims to show multiple unfinished books under **Currently reading**. The direct Exit patch adds a top-bar action, and Quiet's sheet also receives an exit action. An independent-library setting suppresses Quiet's Amazon catalogue and Store button. These behaviours need device testing, including confirmation that exiting saves each book's position.

The SimpleUI override is `integrations/simpleui-2.7.5/module_recent.lua`. It replaces `koreader/plugins/simpleui.koplugin/modules/module_recent.lua` only on that pinned version. Keep a copy of the original first. The Quiet files in this branch keep the same paths as upstream; merge them only while KOReader is closed. Do not copy the entire repository root onto the device.

Changing Home is not the same as removing Amazon firmware. The new Currently reading module uses reading history, so books must have been opened in KOReader; files copied over USB do not automatically count as currently reading. Clock, statistics, goals and quotes remain in the proposed layout at smaller scales.

The acceptance check is deliberately practical: open two books and advance each, return Home and confirm both appear with their own progress. Then visit Settings, use Exit KOReader, reopen the reader and check both positions. Repeat offline and after restarting KOReader. This acceptance pass remains pending; the [device test checklist](TESTING-PAPERWHITE3.md) records the outstanding checks.

## What still needs work

**Cover grid partly blank:** distinguish covers embedded in EPUBs from thumbnails already indexed by the reader. An embedded cover does not prove the library cache has loaded it. Try a single book, return to Library and allow normal indexing. Some PDFs have no dedicated cover image.

**Known unresolved issue:** our library still had gaps in indexed covers. A bulk scanner was unstable. A separately generated compressed cover cache then caused KOReader startup to fail because its frame metadata did not meet the reader's expectations. We restored the earlier native cache and disabled the bulk scanner. Restart success after that rollback has not yet been confirmed. The failed cache generator, private cache database and bulk-scan patch are excluded from this publication.

**KOReader stops opening after a modification:** stop installing more changes. Reconnect by USB after KOReader has closed, preserve the log locally, remove only the newly added patch and restore your own saved settings/plugin files. Do not delete books or factory-reset as a first response. If a generated cover cache caused the failure, restore a known-good cache saved before that experiment. Ask the upstream support community with a redacted log if necessary.

**Quiet settings disappear:** upstream layout changes can hide the normal file-manager menu. Our 035 change aims to restore an explicit Settings tab; verify it before relying on it. Deleting a once-applied change file alone does not undo its settings. Use your saved settings, or a deliberate undo change following Quiet's documented change system.

**No visible difference after restart:** inspect the numbered-change log for success/failure and check that files were copied to `koreader/`, not a nested folder. On macOS, hidden `._` files must not be loaded as Lua scripts.

**Exit is awkward:** the branch adds an Exit KOReader label and touch target for Home/Library/Stats, plus an exit action in Quiet's sheet. This remains a test candidate; confirm saved positions and normal return to the Kindle interface before treating it as solved.

## Keeping a way back

Keep your known-good plugin and settings copies. Follow [Quiet's uninstall instructions](https://github.com/karlosdb/quiet-kindle#uninstall) to remove its patches/plugins and restore settings and book sidecars. Restoring `.sdr` folders can also restore older reading positions. Removing patches without restoring settings is not a complete rollback. Automatic KOReader boot, if separately enabled, needs its own reversal; we did not enable it here.

Do not update SimpleUI independently and assume a 2.7.5 override will still work. Recheck compatibility, change logs and backups before updating the stack. Download packages from maintainers, not copies bundled with books.

## The people and resources behind the project

The jailbreak stage relies on [WinterBreak2 and KindleModding](https://github.com/KindleModding/Winterbreak2), whose guide credits Scam.Net and Penguins184. This fork links to the maintainers' downloads rather than redistributing the exploit archive.

[KOReader](https://github.com/koreader/koreader) supplies the reading engine under AGPL-3.0. [Quiet, created by karlosdb](https://github.com/karlosdb/quiet-kindle), supplies the base project under AGPL-3.0-or-later; its original licence, history and notices remain in [my fork](https://github.com/WelshWT/quiet-kindle/tree/paperwhite3-experimental).

[SimpleUI, created by doctorhetfield-cmd](https://github.com/doctorhetfield-cmd/simpleui.koplugin/tree/2.7.5), supplies the interface modules. The exact 2.7.5 version used here is MIT-licensed, and the derived Recent module retains its [MIT notice](integrations/simpleui-2.7.5/LICENSE). Later versions should not be assumed to use the same licence.

I prepared the Paperwhite 3 article and modifications as WelshWT, with the help of ChatGPT. The new article material is offered under AGPL-3.0-or-later with this fork. The [source code](https://github.com/WelshWT/quiet-kindle/tree/paperwhite3-experimental), [original installation instructions](https://github.com/karlosdb/quiet-kindle#install) and [testing status](TESTING-PAPERWHITE3.md) are available for anyone who wants to inspect or improve the work.

This independent project is not endorsed by Amazon or the upstream developers. No proprietary firmware, Amazon fonts, personal books, private caches, keys or raw device logs are included in our additions.

**Experimental use and responsibility**

This project focuses on customising your own reader and reading documents you have permission to use. Respect the upstream software licences and check the rules applicable to your location.

This is an experimental project, provided without warranty. Some modifications remain unverified, and results may vary by device and firmware.

You choose to follow these instructions and apply the modifications at your own risk. You are responsible for checking compatibility, backing up your files and settings, and any resulting damage, data loss, device malfunction or other consequences, to the extent permitted by applicable law.
