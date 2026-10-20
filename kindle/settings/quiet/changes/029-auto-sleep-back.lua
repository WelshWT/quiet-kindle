-- The review and the sleep-screen work are done: KOReader's own idle sleep goes back to 15 minutes (it was off while
-- Claude and the reviewers worked on the Kindle; Amazon's keep-awake is turned off with bin/kawake off as well).
return {
    note = "sleep: KOReader sleeps after 15 idle minutes again (off during the review)",
    reader = {
        auto_suspend_timeout_seconds = 900,
    },
}
