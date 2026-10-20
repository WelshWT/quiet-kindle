# Quiet: design notes

Why Quiet looks and behaves the way it does, and the research behind each choice. The code comments point here by
section name.

## Principles

- **Work like a Kindle.** People expect a product to work like the ones they already use (Jakob's law; NN/g
  heuristic 4, consistency and standards). Amazon's reader is the baseline for layout, gestures and the Aa menu;
  the difference is what's left out.
- **Everyday actions visible, rare ones one level down.** Hiding navigation cuts discoverability almost in half and
  makes tasks about 15% slower on mobile (NN/g, hamburger menus, 2016); more than two levels of disclosure tests
  poorly (NN/g, progressive disclosure). So the toolbar has five labelled buttons and KOReader's full menus stay
  under More > All KOReader settings, a clearly marked way out (NN/g heuristic 3).
- **Presets over controls.** Fewer than 5% of users changed any of Word's 150+ settings (Jared Spool, "Do users
  change their settings?", 2011); Kindle and Apple Books lead with themes for the same reason, and fewer equal
  choices mean faster decisions (Hick's law). The Text sheet has four Looks; finer settings are changes in
  `kindle/settings/quiet/changes/`, not menus.
- **Words under every icon.** Only home, search and print icons are widely understood without a label (NN/g, icon
  usability). Each meaning has one icon, the one people already know: the gear for settings, ◐ for night mode,
  a moon with a z (IEEE 1621) for sleep rather than ⏻, which reads as "power off".
- **Targets of at least 10 mm.** Fingertips are 16-20 mm; 118 px is 10 mm on the Paperwhite's 300 ppi screen (NN/g,
  touch target size; Material's ~9 mm). Amazon uses about 109 px targets and 136 px rows on the same screen.
- **E-ink friendly.** An interface that changes a small region rarely beats one that changes a large region often
  (epaper-components.dev). Sheets and bars appear in one refresh, with no animation.

## What got smaller

| | KOReader | Quiet |
|---|---|---|
| Reading menu | 7 tabs, 172+ entries | Home + 5 labelled buttons; rare things in More |
| Text settings | 29 controls in 6 tabs | The Kindle's Aa set: size, 4 Looks, font; margins, spacing, alignment |
| Selection pop-up | 13 buttons | 5: Highlight, Note, Ask, Look up, More |
| Home | 5 tabs, rows overflowing | 3 tabs: Home, Library, Stats |

## Reading layout and gestures

- Only the book on the page, and one quiet bottom line, as on a Kindle.
- Tap zones follow the Kindle's EasyReach (measured from Amazon's Paperwhite 12 user guide): the top band (22%)
  brings the toolbar, a narrow left strip (20%) goes back, everything else goes forward; the top-right corner
  bookmarks; a swipe down from the top edge opens the Light sheet.
- The toolbar: "← Home" top left, where Kindle and Kobo put their labelled exit; Text (Aa), Contents, Notes, Search,
  More; at the bottom, where you are and a scrubber. After a jump a "Back to page 7" link appears instead of a
  pop-up you'd have to dismiss.
- Clickable things look clickable: weak signifiers cost people about 22% more time (Kate Moran, "Flat UI Elements
  Attract Less Attention and Cause Uncertainty", NN/g 2017). Lists suit finding a known book, grids suit browsing
  covers, so the Library has both, one tap apart.

## Reading text

The "Standard" look (change 009):

- **Size:** Bookerly at a 47 px em, x-height 24 px = 2.0 mm, 0.33° at 35 cm. Fluent reading needs at least 0.2°; the
  target band is 0.30-0.35° (Legge & Bigelow 2011; screen studies favour about 20% above book print).
- **Line height** 1.45 em for every font (Chung 2004: gains up to about 1.2-1.5× single spacing; extremes hurt,
  Rello 2016).
- **Margins** 4.5 mm at the sides, about 52 characters a line (Dyson & Haselgrove 2001; Tinker; Bringhurst 45-75).
- **Justified and hyphenated**, KOReader's default (costs were only shown for crude or unhyphenated justification),
  1.2 em indents. Normal weight and contrast, black on white (Piepenbrock 2013/2014).
- **Bookerly:** no font is best for everyone (Wallace 2022), and familiarity helps (Beier & Larson 2013), so the
  Kindle's own reading font, with publisher fonts off so every book uses it. The interface uses Amazon Ember. Both
  are already on the Kindle; Quiet only refers to them by name.

Compact, Relaxed and Bold are the other Looks. Layout steps: Normal margins are the Standard look's; Wide matches
Amazon's reader on a Paperwhite (about 13 mm sides, measured from screenshots).

## Shapes

One soft shape system: pills (tab bar, selected tab, buttons, chips, sliders, progress bars, search fields), rounded
covers (8-18 px), cards (24 px), dialogs (32 px), sheets and the toolbar (52 px, Material 3's "extra large"). Lines
between things are replaced by space, and a selected item sits on a light grey capsule instead of turning black.

People reliably prefer curved shapes to sharp-angled versions of the same thing (Bar & Neta 2006, Psychological
Science); a 2022 meta-analysis of 61 studies puts the effect at a medium g = 0.39 (Chuquichambi et al., Annals of the
New York Academy of Sciences); curved rooms are judged more beautiful (Vartanian et al. 2013, PNAS). Consistency
matters as much: one shape per job.

## Search & Ask

- One field, simple and forgiving by default: people rarely use advanced options and do badly reformulating queries
  (first-try success 51%, then 32%, then 18%; Jakob Nielsen, "Search: Visible and Simple", 2001). Words are found
  offline, straight away, ignoring capitals and accents.
- No spoilers: the AI reads the chapters before yours (up to about 100k tokens), your chapter up to your page, and
  your page or selection as the focus, and nothing past it unless the one switch, "What's ahead", is on. Amazon's
  own "Ask this Book" (Kindle app, December 2025) limits answers to the reading position the same way. Answers cite
  pages you can tap.
- Optional semantic search: TypeSafe's Jev picks the passage closest in meaning and decides whether you're finding
  words or asking.
- The page never freezes while an answer streams: requests run in a child process. Certificates are checked against
  KOReader's CA bundle, and keys live only on the Kindle.

## Stats

| | What | Why |
|---|---|---|
| Streak | Days in a row, the last seven as a chain, your best. One quiet day a week is forgiven; a gap never says "you broke it". | A visible streak keeps people going and a broken one makes them quit unless it can be repaired (Silverman & Barasch 2023, Journal of Consumer Research). Missing one day doesn't slow habit-building (Lally et al. 2010). |
| This week vs last | Minutes per day as bars, last week as an outline. A fresh week every Monday. | Fresh starts raise goal pursuit (Dai, Milkman & Riis 2014). Bar length is the most accurately read encoding (Cleveland & McGill 1984). |
| Now reading | Time left and when you'll finish at your pace. | Effort rises near the finish line (Kivetz, Urminsky & Zheng 2006). |
| This year | Books finished, per month, a wall of covers, a few highlights. | Spotify Wrapped and StoryGraph show one striking number at a time, not dense charts. |
| No nagging | No reminders, goals or badges. | Nudges after a missed day mostly don't work (Barasch 2023). |

**Honest reading time.** KOReader keeps a page visit of over 2 minutes as exactly 2 minutes, so a book left open
until the screensaver counts as reading. Quiet uses your own pace (the median of your ordinary page visits) and counts
each page for at most twice that. Before there's any history the guess is about 37 s a page: around 147 words a page
at a typical text size, at the 238 words a minute adults read on average (Brysbaert 2019). Time left runs to the end
of the story, not the end of the file.

**Finished.** A book is finished when you turn into its back matter (Acknowledgments, Notes, Index…), found from the
contents, not at the last page: on real books the story ends anywhere from 87% to 99%.

## Automatic light

Amazon's auto light has ten fixed bands of room light, one level each: crossing a band edge jumps the light 2-4
levels, everything under 15 lux is one band, and a hand adjustment overwrites its band and drags the neighbours along.
Quiet's Auto (on the Light sheet):

- **Smooth:** the same levels as a smooth curve (monotone cubic in log lux), with a darker floor for a pitch-black
  room; it fades one level at a time.
- **Not fooled by your hand:** it goes by the brightest reading of the last 4 s and changes only once the new light
  has held (2 s brighter, 6 s darker) and moved at least 25%, as Android's AutomaticBrightnessController does.
- **Sees real darkness:** the sensor is read directly, down to 0.01 lux.
- **Learns gently:** a slider move is a preference at that light; the curve bends through it (fully there, half as
  much at 3× or ⅓ of the light) and averages with earlier choices. What you set holds until the room light moves by
  more than about 60% (Android's short-term model, BrightnessMappingStrategy).
- **Off in daylight**, about 6 ms of work every 2 s while the screen is on, nothing while asleep. Amazon's own Auto is
  paused only while KOReader runs and given back when it exits.

E-paper legibility studies put the limit for keeping reading performance at about 300 lux of room light, and
lighting-comfort work (tablet comfort from 150 to 15,000 lux, MDPI Applied Sciences 11:8679, 2021; screen-to-ambient
luminance ratio, Lighting Research & Technology, 2024) shows the page should stay in proportion to its surroundings.

## Speed

Measured on the Kindle with `bin/ktrace`; see the Speed table in README.md. A page turn is about 30 ms of KOReader
work plus about 205 ms of e-ink waveform, the same as Amazon's reader; that part is the screen itself.

## Sources

Amazon Kindle Paperwhite (12th gen) user's guide; Amazon help, "Customize your Kindle e-reader text display"; Kobo
help center (Reading menu, font settings, gestures); Apple iPhone User Guide, "Read books"; NN/g on progressive
disclosure, hamburger menus, icon usability, recognition vs recall, touch target size and the ten usability
heuristics; Laws of UX (Jakob's law, Hick's law); Jared Spool, "Do users change their settings?" (2011); Luke
Wroblewski, "Obvious Always Wins"; epaper-components.dev; KOReader 2026.07.1 and SimpleUI 2.7.5 source. Light:
AOSP AutomaticBrightnessController and BrightnessMappingStrategy; US patent 8,749,538 (front-light comfort study);
MDPI Applied Sciences 11:8679 (2021); Lighting Research & Technology (2024). Search: Jakob Nielsen, "Search: Visible
and Simple" (2001); TypeSafe's Jev documentation; coverage of Amazon's "Ask this Book" (December 2025). Clickability:
Kate Moran, NN/g (2017). Stats: Silverman & Barasch, Journal of Consumer Research 49(6), 2023; Lally et al., European
Journal of Social Psychology, 2010; Dai, Milkman & Riis, Management Science, 2014; Kivetz, Urminsky & Zheng, Journal
of Marketing Research, 2006; Cleveland & McGill, JASA, 1984; Brysbaert, Journal of Memory and Language, 2019. Reading
text: Legge & Bigelow 2011; Chung 2004; Rello 2016; Dyson & Haselgrove 2001; Piepenbrock 2013/2014; Wallace 2022;
Beier & Larson 2013. Shapes: Bar & Neta 2006; Chuquichambi et al. 2022; Vartanian et al. 2013.
