#!/bin/sh
# Amazon's automatic light and status bar while KOReader runs: patches/2-quiet-light.lua stops Amazon's auto light
# (so KOReader's own Auto, or manual brightness, is the only thing moving the light) and keeps Amazon's status bar
# paused (its clock would paint over KOReader; nothing else pauses or resumes it), and both must come back exactly
# as found however KOReader ends.
# Every step that reads or changes that state is here, under one lock, so they can't interleave, and the laptop
# test runs exactly this file.
#
#   quiet-amazon-guard.sh takeover <pid>   at KOReader's start. Makes <pid> the owner (only with its crash watcher
#                                          running), stops Amazon's auto (owed back if it was on), pauses the status
#                                          bar. Exit 0 only if Amazon's auto is known to be off: only then may
#                                          2-quiet-light.lua move the light (the two would fight over it).
#   quiet-amazon-guard.sh giveback <pid>   at a clean exit, if <pid> still owns them: status bar on, Amazon's auto
#                                          back on if owed, checked, marked; exit 0 only if all of it took (then the
#                                          watcher stands down). Not the owner: nothing to give back.
#   quiet-amazon-guard.sh watch <pid>      the crash watcher (started by takeover): once <pid> is gone without a
#                                          clean give-back, and it is still the owner, gives everything back.
#
# State. Persistent (survives a reboot): OWED = Amazon's auto was on when taken over; RESTORED = we gave it back
# (recorded just before, and kept even if the turn-on failed: the debt is then forgiven): nothing is owed while it is
# there. A start that finds Amazon's auto off although RESTORED is there knows it was switched off in Amazon's
# settings since: nothing is owed any more. RESTORED goes only when a new debt is incurred or the old one forgotten.
# Volatile (/tmp): the lock, OWNER (pid of the KOReader that owns Amazon's things), and each clean exit's mark.
# Exit codes: 0 done, 2 usage, 3 couldn't take the lock (nothing was touched), 4 a give-back didn't take (or couldn't
# be recorded), 5 taken over but Amazon's auto not known to be off (unreadable, or it wouldn't switch off), 6 not
# taken over: the owner couldn't be recorded, or <pid> is gone (nothing was changed).

STATE=${QUIET_GUARD_STATE:-/mnt/us/koreader/settings/quiet}
RUN=${QUIET_GUARD_RUN:-/tmp}
WAIT=${QUIET_GUARD_WAIT:-10} # seconds a start or an exit waits for the lock (the watcher waits as long as it takes)
POLL=${QUIET_GUARD_POLL:-30} # seconds between the watcher's looks at its KOReader
LOCK=$RUN/quiet-amazon.lock
OWNER=$RUN/quiet-amazon-owner
OWED=$STATE/amazon-auto-owed
RESTORED=$STATE/amazon-auto-restored
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

# The lock on fd 9 within $WAIT seconds. The Kindle's sh (busybox) runs its own flock applet, which has no -w and
# whose sleep takes no fractions: so try without waiting (-n), five times a second.
nap() { usleep 200000 2>/dev/null || sleep 0.2; }
lock9() {
    n=0
    until flock -n -x 9; do
        n=$((n + 1))
        [ "$n" -ge $((WAIT * 5)) ] && return 1
        nap
    done
}

# Amazon's auto (flAuto) as powerd says it, asked up to five times a fifth of a second apart (a busy moment is not
# an unknown answer); empty if it never answers.
auto() {
    for try in 1 2 3 4 5; do
        v=$(lipc-get-prop com.lab126.powerd flAuto 2>/dev/null) && [ -n "$v" ] && { echo "$v"; return 0; }
        [ "$try" = 5 ] || nap
    done
    return 1
}
set_auto() { lipc-set-prop com.lab126.powerd flAuto "$1" 2>/dev/null && [ "$(auto)" = "$1" ]; }

# A mark that must outlive a crash or a power cut: written, then synced. (touch, not ": >": a failed redirection on
# a special builtin would end the whole script instead of failing this step.)
mark() { touch "$1" 2>/dev/null && sync && [ -e "$1" ]; }

takeover() {
    # A takeover that got the lock late, its KOReader killed while it waited, must not displace a newer owner (or
    # leave a dead one whose watcher gives everything back under the newer KOReader).
    kill -0 "$1" 2>/dev/null || return 6
    # Ownership before anything is changed, and never an owner without a watcher. The record is written aside and
    # read back (a full /tmp must not truncate the previous owner's record: its watcher may still be due), this
    # KOReader's crash watcher started (without the lock's fd), and only then the record put in place, in one step.
    printf '%s\n' "$1" 2>/dev/null > "$OWNER.new"
    if [ "$(cat "$OWNER.new" 2>/dev/null)" != "$1" ]; then rm -f "$OWNER.new"; return 6; fi
    setsid sh "$SELF" watch "$1" </dev/null >/dev/null 2>&1 9>&- &
    mv -f "$OWNER.new" "$OWNER" 2>/dev/null || { rm -f "$OWNER.new"; return 6; }
    # Amazon's auto. Every step on the marks is checked before the next relies on it (a read-only /mnt/us fails them
    # all): RESTORED goes before every switch-off, so while it is there nothing is owed (see giveback).
    a=$(auto); off=
    if [ "$a" = 1 ]; then
        # a debt that can't be recorded is never incurred; a switch-off that fails after it leaves a harmless one
        rm -f "$RESTORED"
        [ ! -e "$RESTORED" ] && mark "$OWED" && set_auto 0 && off=1
    elif [ "$a" = 0 ]; then
        off=1
        # switched off in Amazon's settings since our give-back: nothing owed any more (the mark goes only after
        # the debt, synced: if the debt stays, even across a power cut, so does the mark)
        if [ -e "$RESTORED" ]; then rm -f "$OWED"; sync; [ -e "$OWED" ] || rm -f "$RESTORED"; fi
    fi
    # (Amazon's auto unreadable: nothing about it is decided or forgotten this time)
    # the status bar: paused while this KOReader owns it, whatever Amazon's auto said
    killall -STOP JunoStatusBarDriver 2>/dev/null
    [ -n "$off" ] || return 5
}

giveback() {
    killall -CONT JunoStatusBarDriver 2>/dev/null
    # owed: switched off by us and not given back since
    [ -e "$OWED" ] && [ ! -e "$RESTORED" ] || return 0
    # Recorded before it is done, and never taken back: Amazon's auto is never on because of us without RESTORED on
    # disk, so the user switching it off afterwards is never taken for a debt still owed. A read of 0 after the
    # turn-on can't tell "it didn't take" from the user switching it off meanwhile, so a turn-on that fails or can't
    # be read back forgives the debt (Amazon's auto left off, which the user sees and can change) rather than try
    # again against a choice. The read only decides the exit code.
    mark "$RESTORED" || return 1
    lipc-set-prop com.lab126.powerd flAuto 1 2>/dev/null
    [ "$(auto)" = 1 ]
}

case "$1" in
    takeover)
        [ -n "$2" ] || exit 2
        ( lock9 || exit 3; takeover "$2" ) 9>"$LOCK" ;;
    giveback)
        [ -n "$2" ] || exit 2
        # only the owner's: a give-back that gets the lock late (its KOReader killed meanwhile, a newer one has taken
        # over) must not undo the newer one's takeover; and a KOReader that never became the owner has none to give
        ( lock9 || exit 3
          [ "$(cat "$OWNER" 2>/dev/null)" = "$2" ] || exit 0
          giveback || exit 4
          touch "$RUN/quiet-clean-exit.$2" ) 9>"$LOCK" ;;
    watch)
        [ -n "$2" ] || exit 2
        while kill -0 "$2" 2>/dev/null; do sleep "$POLL"; done
        if [ -e "$RUN/quiet-clean-exit.$2" ]; then rm -f "$RUN/quiet-clean-exit.$2"; exit 0; fi
        ( flock -x 9 || exit 3
          [ "$(cat "$OWNER" 2>/dev/null)" = "$2" ] || exit 0   # a newer KOReader owns them now
          giveback || exit 4 ) 9>"$LOCK" ;;
    *) echo "usage: $0 takeover|giveback|watch <pid>" >&2; exit 2 ;;
esac
