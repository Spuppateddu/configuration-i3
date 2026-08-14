#!/usr/bin/env bash
# Emits the bar's layout density (tier + gaps) and the output it lives on:
# {"tier":"dense","mon":"eDP-1","w":1366,"gap":4,"group":6,"item":6,"tray":96}

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# eww_lib sources runtime_lib itself, so i3rc_runtime_dir arrives with it.
source "$REPO/scripts/eww_lib.sh" || exit 1       # primary_output, primary_output_wait
source "$REPO/scripts/emit_lib.sh" || exit 1      # resubscribe_loop

LAST_MON="" LAST_W=""    # last output that resolved, for the guards in emit
LAY_TIER=""
OUT=""                   # the JSON line emit built, read back by emit_changed

# True when the burst in $1 could have changed the outputs: workspace events
# carry `current`, output events don't. Anything unparseable errs to "re-read".
event_touches_output() {
    local l
    while IFS= read -r l; do
        case "$l" in *'"current"'*) ;; *) return 0 ;; esac
    done <<<"$1"
    return 1
}

# $1 is the raw event burst, empty on the first emit of every (re)connect —
# see scripts/emit_lib.sh.
emit() {
    local mon w gap group item tray

    # Skip the get_outputs round trip on workspace events — half the forks a
    # held-down workspace key costs.
    if [ -n "$1" ] && [ -n "$LAST_MON" ] && ! event_touches_output "$1"; then
        mon=$LAST_MON w=$LAST_W
    else
        read -r mon w < <(primary_output)   # primary, else first active output
        case "$w" in ''|*[!0-9]*) w=1920 ;; esac
        # `mon` is interpolated into a jq program and a JSON string in eww.yuck;
        # pinned to a safe charset here so neither site has to quote it.
        mon=${mon//[^A-Za-z0-9._-]/}

        # An empty `mon` puts every workspace in the detached cards. Keep the
        # last good name across a transient; the next event corrects it.
        if [ -z "$mon" ]; then
            [ -n "$LAST_MON" ] || return 1
            mon=$LAST_MON w=$LAST_W
        fi
    fi
    LAST_MON=$mon LAST_W=$w

    # Nothing on the bar is elastic any more (the marquee title was), so a tier
    # is just the width bracket its gaps and tray reserve were tuned for.
    if   [ "$w" -ge 1800 ]; then
        LAY_TIER=wide;    gap=6 group=8 item=3 tray=120
    elif [ "$w" -ge 1500 ]; then
        LAY_TIER=compact; gap=4 group=6 item=3 tray=96
    else
        LAY_TIER=dense;   gap=4 group=6 item=6 tray=96
    fi

    # Into OUT, not stdout: `out=$(emit)` would discard the LAY_*/LAST_* state
    # emit_changed needs, since the subshell's assignments are lost.
    printf -v OUT '{"tier":"%s","mon":"%s","w":%s,"gap":%s,"group":%s,"item":%s,"tray":%s}' \
        "$LAY_TIER" "$mon" "$w" "$gap" "$group" "$item" "$tray"
}

# Workspace events fire on every focus change; only re-emit when the layout
# actually moved.
last=""
emit_changed() {
    emit "$@" || return
    [ "$OUT" = "$last" ] && return
    last="$OUT"
    printf '%s\n' "$OUT"
}

# i3 starts this before X has configured its outputs; without the wait the first
# emit has an empty `mon` and a 1920 fallback width, and may never self-correct.
primary_output_wait >/dev/null

events() { i3-msg -t subscribe -m '["output","workspace"]'; }

# Cleared per (re)connect: the value eww still holds must be re-sent
# unconditionally, or a dead deflisten freezes the layout for good.
reset_dedup() { last=""; }

resubscribe_loop reset_dedup emit_changed events
