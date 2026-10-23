#!/usr/bin/env python3
"""make_words.py OUT.gz WORDLIST.combined.gz [WORDLIST.combined.gz ...]

The keyboard's English word list (kindle/data/quiet-keyboard/en.words.gz) from AOSP's own keyboard word lists,
US and British English merged (books spell both ways):
https://android.googlesource.com/platform/packages/inputmethods/LatinIME/+/refs/heads/main/dictionaries/en_US_wordlist.combined.gz
https://android.googlesource.com/platform/packages/inputmethods/LatinIME/+/refs/heads/main/dictionaries/en_GB_wordlist.combined.gz
(Apache License 2.0, Copyright The Android Open Source Project; see NOTICE). A hand-curated vocabulary of ~160k words,
each with a frequency f from 0 to 255 on a log scale: the kind of list Google's keyboard paper says a keyboard needs
("trained to a fixed vocabulary that has been hand-curated to eliminate misspellings").

Each line of OUT: key, f, flags, and the word as written when it isn't the key, tab-separated, sorted by key:
  key    lower case, accents dropped (é -> e: they sit on the same key), only a-z and the apostrophe
  flags  "o" for words AOSP marks offensive (valid when typed, never offered)
Words that can't be typed as one word here (hyphens, digits, symbols) and AOSP's "not a word" entries are left out.
Then the corrections AOSP's list always makes ("whitelist" shortcuts), as "=" key, tab, replacement, but only those
whose typed form isn't a word itself: im -> I'm, didint -> didn't, wierd -> weird stay; lust -> list, dame -> same,
ill -> I'll, lets -> let's don't (each of those is a real word, often in books).
"""
import gzip
import sys
import unicodedata

# shortcuts AOSP makes that would still change real words found in books (not in its list, but words all the same)
NOT_CORRECTED = {"mote", "mot"}


def key_of(word):
    out = []
    for ch in word:
        base = unicodedata.normalize("NFD", ch)[0].lower()
        if not ("a" <= base <= "z" or base == "'"):
            return None
        out.append(base)
    return "".join(out)


def read(src, entries, shortcuts):
    last = None
    with gzip.open(src, "rt", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith(" word="):
                fields = dict(p.split("=", 1) for p in line.strip().split(","))
                last = fields
                if fields.get("not_a_word") == "true":
                    continue
                word = fields["word"]
                key = key_of(word)
                if not key or len(key) > 24:
                    continue
                offensive = fields.get("possibly_offensive") == "true" or fields.get("flags") == "offensive"
                old = entries.get(word)
                freq = int(fields["f"])
                if old is None or freq > old[1]:
                    entries[word] = (key, freq, "o" if offensive or (old and old[2]) else "", word)
            elif line.startswith("  shortcut=") and last is not None:
                fields = dict(p.split("=", 1) for p in line.strip().split(","))
                if fields.get("f") == "whitelist":
                    shortcuts.append((key_of(last["word"]), fields["shortcut"]))


def main(dst, *srcs):
    entries, shortcuts = {}, []
    for src in srcs:
        read(src, entries, shortcuts)
    entries = list(entries.values())
    valid = {e[0] for e in entries}
    entries.sort(key=lambda e: (e[0], -e[1], e[3]))
    with gzip.open(dst, "wt", encoding="utf-8", compresslevel=9) as out:
        for key, freq, flags, word in entries:
            out.write("\t".join([key, str(freq), flags] + ([word] if word != key else [])) + "\n")
        kept = 0
        for key, target in sorted(set(shortcuts)):
            if key and key not in valid and key not in NOT_CORRECTED:
                out.write("=" + key + "\t" + target + "\n")
                kept += 1
    print(f"{len(entries)} words, {kept} of {len(set(shortcuts))} shortcuts -> {dst}", file=sys.stderr)


if __name__ == "__main__":
    main(*sys.argv[1:])
