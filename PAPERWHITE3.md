# How I gave my old Kindle a new reading life

A personal experiment by WelshWT, made with the help of ChatGPT and built on the work of the Kindle modding community. **Experimental project · updated 11 November 2026.**

This is my account of modifying a Kindle Paperwhite from 2015: what I changed, the tools I used, what worked and what still needs testing. The [project webpage](https://welshwt.github.io/quiet-kindle/) and [experimental fork](https://github.com/WelshWT/quiet-kindle/tree/paperwhite3-experimental) document the work. This is a record of my particular setup rather than a universal installation procedure.

## How ChatGPT helped me

**I made this project with the help of ChatGPT.** I connected the Kindle to my Mac over USB and worked through device identification, installation, file organisation and troubleshooting with an assistant.

The physical connection mattered: the Kindle had to appear as a USB drive before its files could be inspected or changed. My workflow used a Mac; the preparation resources also cover Windows PCs. I kept the reader offline during the initial checks and preparation.

I asked for the model and firmware to be checked first, for each stage to be explained, and for results to be checked before moving on. I also set an explicit boundary around changes: inspection first, with approval before installation, deletion or jailbreaking.

An ordinary chat does not gain access to a connected device simply because a USB cable is plugged in. In my workflow, direct inspection and file changes depended on the local tools and permissions available to the assistant. Manual guidance is a separate option when those tools are absent. I used the upstream documentation as the reference for the device-specific steps.

## Why I wanted a different reading experience

I wanted to upload my own documents, organise them in a way that made sense to me and read without needing an Amazon account for everyday offline use.

A library full of support folders, a Home screen that missed the books I was reading and an awkward route to exit the reader all got in the way. I often read several books at once. My ideal Home screen would show those books and their progress, with smaller clock and statistics widgets around them.

The project brought together [KOReader](https://github.com/koreader/koreader), [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) and [Quiet](https://github.com/karlosdb/quiet-kindle). I wanted local EPUB and PDF reading, straightforward USB transfers, collections and a calmer interface.

Amazon's operating system remains underneath. I have not replaced the firmware, removed every Amazon service, installed Tailscale or enabled automatic boot into KOReader. Optional cloud AI is unnecessary for local reading.

## The Kindle and software I used

My device was a **Kindle Paperwhite 3, 7th generation (2015)** running **firmware 5.16.2.1.1**. The setup used **KOReader 2026.07.1**, **SimpleUI 2.7.5** and [Quiet upstream commit 783a1c1](https://github.com/karlosdb/quiet-kindle/commit/783a1c15e1917337f33c0f54517c3b75d652e3ea).

The model and firmware information came from Kindle Settings → Device Options → Device Info and the device inspection. The [KindleModding compatibility wizard](https://kindlemodding.org/jailbreak-wizard.html) was the reference for selecting a jailbreak route.

That distinction mattered. Similar-looking Kindles can require different methods, and a record of my firmware does not establish compatibility with another reader. I have kept the full serial number out of this publication.

## Preparing my Kindle before Wi-Fi

The Kindle initially had about 10% battery, so charging came before modification. It later reached 57% before the process continued. The preparation target discussed was at least 50%, as a conservative working choice rather than a claim about an official minimum.

I confirmed the USB connection and kept Airplane Mode on during preparation. The [KindleModding preparation overview](https://kindlemodding.org/jailbreaking/) and [update-prevention instructions](https://kindlemodding.org/jailbreaking/prevent-auto-update/) explained the risk of an unwanted firmware update while online.

Temporary filler files were used to limit free space during that stage. This was a temporary measure, not the intended long-term storage arrangement. The maintained procedure, rather than a generic storage-filling command, was the reference.

Backup was also part of the discussion. I initially chose to proceed without one; later, during the book-library work, I copied the material I wanted to preserve to external storage. Those were my choices in this experiment, not evidence that backups are unnecessary.

For KOReader, the relevant recovery material includes `settings.reader.lua`, `settings/`, `defaults.custom.lua` if present, and each book's `.sdr` folder. Quiet can clear per-book font and layout overrides, so a copy of the book files alone does not preserve all reading preferences or positions.

## What happened with WinterBreak2

The jailbreak route used in my setup was [WinterBreak2](https://kindlemodding.org/jailbreaking/WinterBreak2/), release **1.1.0**, obtained through the [official release resources](https://github.com/KindleModding/Winterbreak2/releases).

The archive was extracted to the Kindle's top-level storage as directed by the maintained instructions. After safely ejecting the device, I connected to Wi-Fi for the browser stage. Finding the browser was one of the small points of confusion: its label can be Web Browser or Experimental Browser depending on the firmware.

The maintained WinterBreak2 page supplied the browser address and jailbreak action. The Kindle restarted during the process, but the restart alone was not the confirmation I relied on.

On my device, `documents/JAILBROKEN.txt` recorded success, and KPM commands subsequently worked. I returned the reader to Airplane Mode after the online stages.

The [post-jailbreak documentation](https://kindlemodding.org/jailbreaking/whats-next/) covered the next steps, including temporary filler removal and update protection. Downloaded firmware files needed to be identified specifically; arbitrary `.bin` files were not interchangeable with unwanted updates.

## Getting KOReader running

The references for this stage were the [KindleModding post-jailbreak guide](https://kindlemodding.org/jailbreaking/whats-next/) and [KOReader's Kindle installation documentation](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices).

Package selection depended on the firmware. The word Kindle in an archive name was not enough to establish that it was the right build.

My jailbreak supplied KPM. The following commands were entered one at a time in the Kindle's search bar, waiting for each operation to finish:

```text
;kpm update
;kpm install koreader
;kpm launch koreader
```

These were Kindle search commands, not commands run in Mac Terminal. They describe the KPM route available in my setup; other jailbreak environments may use a different installation method.

KOReader opened its quickstart guide, and I subsequently opened books in it. A complete reading-position check across closing, reopening and restarting remains part of the project's device acceptance checklist rather than a result I am claiming here.

## Adding SimpleUI and Quiet

[SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) supplied interface modules, and [Quiet](https://github.com/karlosdb/quiet-kindle) built on them. I used the [SimpleUI 2.7.5 release](https://github.com/doctorhetfield-cmd/simpleui.koplugin/releases/tag/2.7.5); the modifications in this fork have not been checked against newer versions.

Quiet was developed on a newer Paperwhite. Its upstream screenshots and timing measurements are not measurements of my Paperwhite 3.

The installation put `simpleui.koplugin` inside `koreader/plugins/`. Quiet's `kindle/` folder mirrored the contents of the Kindle's `koreader/` folder, so the contents were merged there rather than placed inside a nested `koreader/kindle/` directory. [Quiet's installation documentation](https://github.com/karlosdb/quiet-kindle#install) was the reference.

The file changes were made with KOReader closed. Its settings can be rewritten on exit, which makes editing them while it is running unreliable.

Quiet changed more than appearance. It applied shared text settings and tap zones. The change file `settings/quiet/changes/011-faster-transitions.lua` also disables optional plugins, including calibre, OPDS and syncing features. That behaviour matters when deciding which parts of the upstream profile fit a particular reading workflow.

After the device was ejected and KOReader restarted, Quiet applied its numbered changes. The useful troubleshooting records were `koreader/settings/quiet/log.txt` and `koreader/crash.log`.

KOReader's local reading features did not need an API key or an Amazon account. Optional cloud features were not necessary for the offline experience I wanted. That observation does not establish the account requirements of every Kindle's initial setup or jailbreak route.

A Mac-specific problem appeared here: Apple's hidden `._` companion files were being mistaken for Quiet change scripts. The modified loader ignores dot-prefixed files. The setup log then showed the original numbered changes applying. This is the most directly confirmed code fix in my fork.

## Rebuilding my document library

The library work focused on EPUB and PDF files in `documents/`, transferred over USB. Categories such as `documents/Fiction/`, `documents/Non-fiction/` and `documents/Reference/` illustrate the kind of folder arrangement I wanted. Collections offer a separate way of grouping books inside compatible reader interfaces.

The experimental profile sets KOReader's home folder to `documents/`, locks normal browsing to that location and hides hidden or unsupported entries. Its aim is to keep support folders such as `koreader` and `libkh` out of the normal book view while leaving those tools intact on storage.

That restriction still needs a final on-device check. The intended behaviour and a verified result are different things.

KFX files were not useful inputs for the offline KOReader workflow I wanted. Renaming the extension would not turn them into EPUBs. The useful alternatives were EPUB or PDF originals with appropriate permission for copying and conversion.

For my own DOCX material, the format choices were PDF for a fixed page layout or EPUB for more flexible reading. Headings, images and reading order still require inspection after conversion. DRM-free also does not mean copyright-free.

Duplicate checking combined exact-file comparisons with review of titles, authors and editions. A matching title alone was not enough to establish that two files were duplicates: different editions, or PDF and EPUB versions, can be intentionally different.

## What I changed in the fork

I published the additions for inspection and experimentation, with [the source and test checklist](TESTING-PAPERWHITE3.md) recording their status. I am not presenting this branch as a verified one-click upgrade.

Alongside the confirmed Mac file-loader fix, **change 034** configures five larger book rows per Library page. The configuration was applied, but its final appearance and cover sizing still need a visual check on the six-inch screen.

**Change 035** aims to restore visible interface settings after the usual menu became hidden. Its Settings interaction still needs checking.

**Change 036** combines the documents-only library with a more compact Home layout. Its application was recorded in the log, but the final screen and interactions remain unverified.

A separate SimpleUI module aims to show multiple unfinished books under **Currently reading**. The direct Exit patch adds a top-bar action for Home, Library and Stats, and Quiet's sheet also receives an exit action. An independent-library setting suppresses Quiet's Amazon catalogue and Store button. These behaviours still need device testing, including confirmation that exit preserves reading positions.

The separate integration file is [module_recent.lua](integrations/simpleui-2.7.5/module_recent.lua). It replaces `koreader/plugins/simpleui.koplugin/modules/module_recent.lua` in the pinned 2.7.5 plugin. It is not a claim of compatibility with another SimpleUI version.

The Quiet files retain the same relative paths as upstream. My installation work merged those files into the corresponding KOReader folders while it was closed; the entire repository root was not the device payload. The original module and settings are the relevant rollback material for that replacement.

The proposed Currently reading module uses history, so a book must have been opened in KOReader to appear there. Copying it over USB does not automatically make it a current read. Clock, statistics, goals and quotes remain in the proposed layout at smaller scales.

My pending acceptance check involves opening two books, advancing each and confirming that both appear on Home with their own progress. It also covers the Settings tab, clean exit from Home/Library/Stats, adjacent top-bar touch targets, document-folder browsing and saved positions after reopening. Repeating those checks offline and after restart is recorded in the [device test checklist](TESTING-PAPERWHITE3.md).

## The problems I have not finished solving

Cover indexing remained uneven. A cover embedded in an EPUB is different from a thumbnail already indexed by the reader. A valid embedded image did not establish that the library cache had loaded it, and some PDFs lacked a dedicated cover image. Normal single-book indexing is still part of the outstanding checks.

A bulk scanner proved unstable. A separately generated compressed cover cache then caused KOReader to fail at startup because its frame metadata did not meet the reader's expectations. I restored the earlier native cache and disabled the bulk scanner. Successful startup after that rollback has not yet been confirmed.

The failed cache generator, private database and bulk-scan patch are excluded from the publication. I have left the failure in this account because it is part of what happened.

That problem also clarified the recovery approach: stop layering on changes, preserve the log locally and identify the specific new patch, settings file, plugin or generated cache involved. A known-good saved copy matters more than deleting books or jumping to a factory reset. Redacted logs are the appropriate material for an upstream support discussion.

Another issue was the missing Quiet settings. Upstream layout changes could hide the normal file-manager menu; change 035 was my attempt to restore an explicit Settings tab. Deleting a once-applied change file alone does not reverse the settings it wrote. A saved settings copy or deliberate undo change is needed for that.

When a restart appeared to change nothing, the checks were the numbered-change log, the copy destination and the hidden Mac files. The same distinction applies to Exit: the presence of a label is not proof that clean exit and saved positions work correctly.

## Keeping the experiment reversible

The recovery reference is [Quiet's uninstall documentation](https://github.com/karlosdb/quiet-kindle#uninstall), which covers removing its patches and plugins and restoring settings and book sidecars.

Restoring `.sdr` folders can restore older reading positions as well. Removing code without restoring the settings it changed is not a complete rollback. Automatic KOReader boot would require its own reversal if separately enabled; I did not enable it here.

The SimpleUI 2.7.5 override also makes version changes significant. I have not established that an independent SimpleUI update will preserve compatibility. Compatibility notes, change logs and saved copies remain part of any future update work. The package sources used in this account are the maintainers' resources, not software bundled with book downloads.

## The people and resources behind my experiment

[WinterBreak2 and KindleModding](https://github.com/KindleModding/Winterbreak2) supplied the jailbreak route. The maintained guide credits Scam.Net and Penguins184. My publication links to their downloads rather than redistributing the exploit archive.

[KOReader](https://github.com/koreader/koreader) supplied the reading engine under AGPL-3.0. [Quiet, created by karlosdb](https://github.com/karlosdb/quiet-kindle), supplied the base project under AGPL-3.0-or-later. Its original licence, history and notices remain in [my fork](https://github.com/WelshWT/quiet-kindle/tree/paperwhite3-experimental).

[SimpleUI, created by doctorhetfield-cmd](https://github.com/doctorhetfield-cmd/simpleui.koplugin/tree/2.7.5), supplied the interface modules. The exact version 2.7.5 source used here is MIT-licensed. The derived Recent module retains its [MIT notice](integrations/simpleui-2.7.5/LICENSE); that statement is specific to this version.

I prepared the Paperwhite 3 article and modifications as WelshWT with ChatGPT's help. The new article material is offered under AGPL-3.0-or-later with the fork. The [source code](https://github.com/WelshWT/quiet-kindle/tree/paperwhite3-experimental), [original installation instructions](https://github.com/karlosdb/quiet-kindle#install) and [testing status](TESTING-PAPERWHITE3.md) document the underlying work.

This is my independent project, without endorsement from Amazon or the upstream developers. My additions contain no proprietary firmware, Amazon fonts, personal books, private caches, keys or raw device logs.

**Experimental purpose and responsibility**

My project focuses on customising my own reader and reading documents I have permission to use. I am sharing my experience and experimental source changes, with the upstream software licences and applicable local rules remaining relevant.

I undertook this experiment at my own risk. Device damage, data loss, malfunction and other consequences were risks I accepted in deciding to modify my Kindle. Some modifications remain unverified, and I make no promise of the same outcome on another device or firmware.

The project is provided without warranty. Any independent decision to reproduce the experiment, including compatibility checks, backups and resulting consequences, remains the responsibility of the person making that decision, to the extent permitted by applicable law.
