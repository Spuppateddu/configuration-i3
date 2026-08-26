#!/usr/bin/env bash
# Emits the bar's layout density (tier + gaps) and the output it lives on:
# {"tier":"dense","mon":"eDP-1","w":1366,"gap":4,...,"title":24,"tray":96}
#
# `title` is the marquee slot in CHARACTERS, never pixels — size.local.scss moves
# the font size. Mirrored to $STATE: player.sh, not eww, renders the marquee.

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# eww_lib sources runtime_lib itself, so i3rc_runtime_dir arrives with it.
source "$REPO/scripts/eww_lib.sh" || exit 1       # primary_output, primary_output_wait
source "$REPO/scripts/emit_lib.sh" || exit 1      # resubscribe_loop

STATE="$(i3rc_runtime_dir)/i3rc-eww-layout"

# Width of 100 chars at the bar's font, x100. Not re-measured; if the title
# over- or under-fills, measure and set it.
CHAR100=639
MARGIN=16      # px kept free so a rounding error never pushes the tray off-screen
WSMON=17       # px the other-monitor marker glyph adds to each detached card
WSTILE=18      # px of one workspace tile (.ws min-width in eww.scss)
WSGAP=4        # px between tiles (wscard's :spacing in eww.yuck)
TITLE_MIN=16
# The slot is a TARGET (`tw` per tier below), not "whatever is left over" — the
# leftover only caps it on a narrow output. `tw` is the one number to change.

LAST_MON="" LAST_W=""    # last output that resolved, for the guards in emit
LAY_TIER="" LAY_TITLE="" # mirrored to $STATE by emit_changed for player.sh
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
    local mon w gap group item tray base ipad tw
    local wsn ndetached wscost

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

    # `base` = px of all but the title and the workspace tiles; `ipad` is an
    # island's padding-x. Over-estimating it only under-fills, so these run high.
    if   [ "$w" -ge 1800 ]; then
        LAY_TIER=wide;    gap=6 group=8 item=3 tray=120 base=980 ipad=8 tw=40
    elif [ "$w" -ge 1500 ]; then
        LAY_TIER=compact; gap=4 group=6 item=3 tray=96  base=890 ipad=6 tw=32
    else
        LAY_TIER=dense;   gap=4 group=6 item=6 tray=96  base=895 ipad=6 tw=24
    fi

    # Workspace tiles are the only variable-width part of the bar. Second field
    # counts *other* outputs — eww.yuck draws one detached card per output.
    read -r wsn ndetached < <(
        i3-msg -t get_workspaces 2>/dev/null | jq -r --arg mon "$mon" '
            "\(length) \([.[] | .output] | unique | map(select(. != $mon)) | length)"
        ' 2>/dev/null
    )
    case "$wsn" in ''|*[!0-9]*) wsn=4 ndetached=0 ;; esac
    case "$ndetached" in ''|*[!0-9]*) ndetached=0 ;; esac

    # Equal squares, so the cost is a count — the label's length stopped
    # mattering when .ws became min-width == min-height.
    wscost=$(( wsn * WSTILE + wsn * WSGAP + 2 * ipad ))
    # Each detached card costs its own island padding plus WSMON for the marker
    # glyph (eww.scss `.wsmon`).
    wscost=$(( wscost + ndetached * (2 * ipad + gap + WSMON) ))

    # `tw` unless the output genuinely cannot fit it; the floor keeps the slot
    # readable even then (a few chars of overflow beat an unusable stub).
    LAY_TITLE=$(( ((w - base - wscost - MARGIN) * 100) / CHAR100 ))
    [ "$LAY_TITLE" -gt "$tw" ] && LAY_TITLE=$tw
    [ "$LAY_TITLE" -lt "$TITLE_MIN" ] && LAY_TITLE=$TITLE_MIN

    # Into OUT, not stdout: `out=$(emit)` would discard the LAY_*/LAST_* state
    # emit_changed needs, since the subshell's assignments are lost.
    printf -v OUT '{"tier":"%s","mon":"%s","w":%s,"gap":%s,"group":%s,"item":%s,"title":%s,"tray":%s}' \
        "$LAY_TIER" "$mon" "$w" "$gap" "$group" "$item" "$LAY_TITLE" "$tray"
}

# Workspace events fire on every focus change; only re-emit (and rewrite the
# state file) when the layout actually moved.
last=""
emit_changed() {
    emit "$@" || return
    [ "$OUT" = "$last" ] && return
    last="$OUT"
    printf 'LAY_TIER=%s LAY_TITLE=%s\n' "$LAY_TIER" "$LAY_TITLE" >"$STATE"
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
