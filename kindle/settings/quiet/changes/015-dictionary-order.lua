-- 014 keyed the order by absolute path; KOReader keys dictionaries by the relative path it found them under
-- (data/dict/...), so 014 had no effect. Same order: WordNet first, then GCIDE.
return {
    note = "dictionaries: WordNet first (relative paths, as KOReader keys them)",
    reader = {
        dicts_order = {
            ["data/dict/WordNet/dictd_www.dict.org_wn.ifo"] = 1,
            ["data/dict/GCIDE/stardict.ifo"] = 2,
        },
    },
}
