#!/bin/sh
# Opens one Kindle Store book in Amazon's reader, or the Kindle Store, once KOReader has handed the screen back,
# then brings KOReader back when it's closed. Started (detached) by quiet_amazon.lua just before KOReader exits;
# see there for why it has to wait for KOReader to be gone.
#
#   sh quiet_amazon_open.sh <request id> <start mark> <app> <uri> [stay]
#
#   request id  this request. Only the latest request may act: KOReader writes its id to /tmp/quiet-amazon.req
#               (and a new one to call a waiting run off). Nothing here writes that file, or any file another run
#               relies on, and nothing here kills anything, so two runs can't undo each other (review C6 rounds 3-4:
#               a pid file that runs claimed and cleaned up could be overwritten or deleted by an older run).
#   start mark  /tmp/quiet-ready of the KOReader session that asked (the bridge writes the time KOReader started
#               there). Any other value later means KOReader started again since: then nothing is started.
#   app, uri    what to start on Amazon's side and the app that shows it.
#   stay        don't bring KOReader back afterwards.
#
# One-shot and self-ending: it never stays past 12 hours, and it ends without acting as soon as its request isn't
# the latest or KOReader is back.

REQ_FILE=/tmp/quiet-amazon.req
LOG=/tmp/quiet-amazon.log
READY=/tmp/quiet-ready
HOME_APP=com.lab126.KPPMainApp
MAX_LIFE=43200 # seconds
WAIT=30 # longest sleep between looks at appmgrd (an event that fires just before we listen is missed)

ID=$1
started_mark=$2
APP=${3:-com.lab126.booklet.reader}
URI=$4
RETURN_TO_KOREADER=1
[ "${5:-}" = stay ] && RETURN_TO_KOREADER=0

log() { echo "$(date '+%H:%M:%S') $*" >>"$LOG"; }
prop() { lipc-get-prop com.lab126.appmgrd "$1" 2>/dev/null; }

mine() { [ "$(cat "$REQ_FILE" 2>/dev/null)" = "$ID" ]; }
restarted() { [ "$(cat "$READY" 2>/dev/null)" != "$started_mark" ]; }
finish() { exit "${1:-0}"; }

[ -n "$ID" ] && [ -n "$URI" ] || { log "no request"; exit 1; }
mine || exit 0

# Amazon's home or library on screen. appmgrd doesn't always fill activeView for the KPP home; its activeContext
# (":0:app://com.lab126.KPPMainApp?view=KPP_HOME") says it then.
at_home() {
    case "$(prop activeApp)" in
        com.lab126.booklet.home) return 0 ;;
        "$HOME_APP") ;;
        *) return 1 ;;
    esac
    case "$(prop activeView)" in
        KPP_HOME | KPP_LIBRARY*) return 0 ;;
        "") case "$(prop activeContext)" in *view=KPP_HOME* | *view=KPP_LIBRARY*) return 0 ;; esac ;;
    esac
    return 1
}

: >"$LOG"
log "open $URI"

# 1. Wait for KOReader and its launcher to finish putting Amazon's UI back (services, window manager, home).
n=0
while pgrep -f "reader[.]lua" >/dev/null 2>&1 || pgrep -f "koreader[.]sh" >/dev/null 2>&1; do
    mine || { log "a newer request: not opening it"; finish 0; }
    restarted && { log "KOReader started again during the handoff: not opening it"; finish 0; }
    n=$((n + 1))
    [ $n -gt 120 ] && { log "KOReader did not exit within 60 s"; finish 1; }
    usleep 500000
done
restarted && { log "KOReader started again during the handoff: not opening it"; finish 0; }
log "KOReader gone after $((n / 2)) s; app=$(prop activeApp)"

# KOReader is back (started some other way: its launcher, its reader, or a new start mark).
koreader_started() {
    pgrep -f "reader[.]lua" >/dev/null 2>&1 && return 0
    pgrep -f "koreader[.]sh" >/dev/null 2>&1 && return 0
    restarted
}
# The one rule for every start this script makes, on either side (review C6 rounds 1-4): it is made only while
# this request is the latest and KOReader isn't back, checked right before it. Each of the three starts below is
# preceded by this.
unless_back() {
    mine || { log "a newer request: not $1"; finish 0; }
    koreader_started && { log "KOReader is back: not $1"; finish 0; }
}

# 2. Let Amazon's home finish taking over: the launcher asks for the old home booklet, which hands over to the
#    KPP home. Started before that, our app pauses the old booklet instead of the home, and the Store's ✕ (back)
#    then has nowhere to go.
n=0
until [ "$(prop activeApp)" = "$HOME_APP" ]; do
    n=$((n + 1))
    [ $n -gt 20 ] && { log "home not up after 10 s (app=$(prop activeApp))"; break; }
    koreader_started && { log "KOReader started again before the book: not opening it"; finish 0; }
    usleep 500000
done
usleep 1000000
log "home up after $((n / 2)) s"

# 3. Open the book or the Store, unless KOReader has meanwhile come back (it would have the screen).
unless_back "opening $APP"
lipc-set-prop com.lab126.appmgrd start "$URI" || log "start refused"
n=0
until [ "$(prop activeApp)" = "$APP" ]; do
    n=$((n + 1))
    if [ $n -gt 80 ]; then
        log "$APP did not come up within 40 s (app=$(prop activeApp))"
        break
    fi
    usleep 500000
done
log "$APP up after $((n / 2)) s; back=$(prop backButtonState)"

[ "$RETURN_TO_KOREADER" = 1 ] || finish 0

# 4. The way back: when Amazon's home (or library) comes up after the book or the Store, start KOReader again.
born=$(date +%s)
settle=0
while :; do
    mine || { log "a newer request: done"; finish 0; }
    koreader_started && { log "KOReader was started another way"; finish 0; }
    [ $(($(date +%s) - born)) -gt $MAX_LIFE ] && { log "gave up after 12 h"; finish 0; }
    if at_home; then
        unless_back "starting KOReader"
        log "back on Amazon's home: starting KOReader"
        lipc-set-prop com.lab126.appmgrd start "file:///mnt/us/documents/KOReader.sh" 2>/dev/null
        # done as soon as KOReader shows any sign of starting (this request's, or anyone's)
        n=0
        until koreader_started; do
            n=$((n + 1))
            if [ $n -gt 30 ]; then
                unless_back "starting KOReader directly"
                log "no KOReader via the library entry, starting it directly"
                /var/local/kmc/bin/kpm launch koreader --asap </dev/null >/dev/null 2>&1 &
                break
            fi
            usleep 500000
        done
        finish 0
    fi
    # appmgrd's events can come a moment before activeApp/activeContext catch up: look again for 2 s
    if [ $settle -gt 0 ]; then
        settle=$((settle - 1))
        usleep 500000
        continue
    fi
    # sleep until appmgrd says something changed, or WAIT seconds at most: an event that fires between the
    # look above and this subscription is lost, and the home would otherwise go unnoticed until the next one
    lipc-wait-event -s "$WAIT" com.lab126.appmgrd '*' >/dev/null 2>&1
    settle=4
done
