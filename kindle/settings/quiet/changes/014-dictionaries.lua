-- Holding a word said "There are no enabled dictionaries" (KOReader can't read Amazon's own). Installed in
-- data/dict (not in this repo, 25 MB): WordNet 3 (Princeton, 149,535 words, modern and short) and GCIDE (GNU
-- Collaborative International Dictionary of English, 108,121 words, Webster's 1913 plus later additions,
-- with example quotations). WordNet answers first; GCIDE is a swipe away.
local DICT = "/mnt/us/koreader/data/dict/"
return {
    note = "dictionaries: WordNet first, then GCIDE",
    reader = {
        dicts_order = {
            [DICT .. "WordNet/dictd_www.dict.org_wn.ifo"] = 1,
            [DICT .. "GCIDE/stardict.ifo"] = 2,
        },
    },
}
