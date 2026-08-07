#!/usr/bin/env bash
# Emits active-player state as JSON for the eww bar (deflisten).
# `display` is always exactly TITLE_W chars: short text is centered,
# longer text marquee-scrolls one char per frame.

export LC_ALL=C.UTF-8

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/scripts/player_lib.sh" || exit 1
source "$REPO/scripts/runtime_lib.sh" || exit 1   # i3rc_runtime_dir
source "$REPO/scripts/emit_lib.sh"    || exit 1   # json_escape

LAYOUT_STATE="$(i3rc_runtime_dir)/i3rc-eww-layout"
TITLE_W=40    # overridden per density tier by layout_w below
SEP="   •   "
FRAMES=6      # scroll frames between metadata refreshes
TICK=0.3

PLAYER="" STATUS="none" TITLE="" ARTIST=""
SRC="" OFFSET=0 SCROLL=0 TEXT=""

# Marquee width follows the density tier screen.sh writes to a state file.
# Parsed, never sourced — sourcing would run that file's contents as shell.
layout_w() {
    local line val
    [ -r "$LAYOUT_STATE" ] || return
    read -r line < "$LAYOUT_STATE" || return
    [ "$line" = "${line#*LAY_TITLE=}" ] && return   # key absent
    val=${line##*LAY_TITLE=}
    val=${val%%[!0-9]*}
    [ -n "$val" ] || return
    [ "$val" -eq "$TITLE_W" ] || { TITLE_W=$val; OFFSET=0; }
}

fetch() {
    layout_w
    # Fills PLAYER/STATUS/TITLE/ARTIST in a single playerctl call.
    player_state
    case "$STATUS" in
        Playing|Paused) ;;
        *) STATUS="none"; TITLE=""; ARTIST="" ;;
    esac

    local text="$TITLE"
    [ -n "$ARTIST" ] && text="$TITLE — $ARTIST"
    [ "$text" = "$SRC" ] || { SRC="$text"; OFFSET=0; }
    SCROLL=$(( ${#SRC} > TITLE_W ? 1 : 0 ))
}

# Renders SRC into TEXT, exactly TITLE_W chars wide.
# Spaces become NBSP: Pango drops trailing spaces when measuring,
# which would make the label width jitter while scrolling.
render() {
    local len=${#SRC}
    if [ "$SCROLL" -eq 0 ]; then
        local pad=$((TITLE_W - len)) left=$(( (TITLE_W - len) / 2 ))
        printf -v TEXT '%*s%s%*s' "$left" "" "$SRC" "$((pad - left))" ""
    else
        local loop="${SRC}${SEP}" twice
        twice="$loop$loop"
        TEXT=${twice:OFFSET:TITLE_W}
        OFFSET=$(( (OFFSET + 1) % ${#loop} ))
    fi
    TEXT=${TEXT// /$'\u00a0'}
}

emit() {
    local js jt ja jd
    render
    json_escape js "$STATUS"
    json_escape jt "$TITLE"
    json_escape ja "$ARTIST"
    json_escape jd "$TEXT"
    printf '{"status":"%s","title":"%s","artist":"%s","display":"%s"}\n' \
        "$js" "$jt" "$ja" "$jd"
}

# No playerctl: emit the idle state once and stop. Looping would only spin on a
# follower that can never start, and eww keeps the last value it was given.
if ! command -v playerctl >/dev/null 2>&1; then
    emit
    exit 0
fi

open_follow() {
    [ -n "${follow_pid:-}" ] && kill "$follow_pid" 2>/dev/null
    exec 3<&-
    exec 3< <(playerctl --follow metadata --format '{{status}}' 2>/dev/null)
    follow_pid=$!
}

# Nothing else reaps the follower, and `playerctl --follow` with no player on
# the bus blocks forever — so it leaks one per i3 restart without this.
cleanup() { [ -n "${follow_pid:-}" ] && kill "$follow_pid" 2>/dev/null; return 0; }
trap cleanup EXIT
trap 'cleanup; exit 0' TERM INT

# Wait for a player event: 0 if one arrived, 1 on timeout. EOF on fd 3 (the
# follower died) must be told from a timeout, or the loop spins at 300k/s.
wait_event() {
    local rc
    read -t "$1" -u 3 -r _ && return 0
    rc=$?
    [ "$rc" -gt 128 ] && return 1      # timed out: no event, as expected
    sleep 1                            # EOF: back off, then reconnect
    open_follow
    return 1
}

open_follow
while :; do
    fetch
    if [ "$SCROLL" -eq 1 ]; then
        # keep scrolling, but refetch early if the player fires an event
        for ((frame = 0; frame < FRAMES; frame++)); do
            emit
            wait_event "$TICK" && break
        done
    else
        emit
        wait_event 2 || true
    fi
done
