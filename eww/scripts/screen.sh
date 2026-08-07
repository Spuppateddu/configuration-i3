#!/usr/bin/env bash
# Emits the bar's layout density (tier + gaps) and the output it lives on:
# {"tier":"dense","mon":"eDP-1","w":1366,"gap":3,...,"title":64,"tray":72}
#
# `title` is in characters — the marquee absorbs whatever the fixed segments
# leave over. Re-measure `base` on screen if the font or paddings change.

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# eww_lib sources runtime_lib itself, so i3rc_runtime_dir arrives with it.
source "$REPO/scripts/eww_lib.sh" || exit 1       # primary_output, primary_output_wait
source "$REPO/scripts/emit_lib.sh" || exit 1      # resubscribe_loop

STATE="$(i3rc_runtime_dir)/i3rc-eww-layout"

# Width of 100 chars at the bar's font, ×100. Derived from font swaps rather
# than re-measured; if the title over- or under-fills, measure and set it.
CHAR100=639
MARGIN=16      # px kept free so a rounding error never pushes the tray off-screen
WSMON=17       # px the other-monitor marker glyph adds to each detached card
TITLE_MIN=16
# The title slot is a TARGET (`tw` per tier below), not "whatever is left over".
# It used to be leftover-width clamped to a ceiling, so on any roomy output it
# simply pinned to that ceiling — 96 chars ≈ 625px of mostly-empty slot on a
# 1920 screen. The leftover is now only an upper bound for genuinely narrow
# outputs; normally the title is exactly `tw` wide and the slack goes to the
# two hexpand spacers, where empty space belongs. Want a longer/shorter title
# panel? Change `tw` — it is the one number that decides it, on every machine.

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
    local mon w gap group item tray base wspad ipad tpad tw
    local wsn wschars wscost ndetached titlepx

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

    # `base` = px of everything but the title and workspace buttons; tpad is
    # .ptitle's own padding. Over-estimating base only under-fills the bar.
    if   [ "$w" -ge 1800 ]; then
        LAY_TIER=wide;    gap=6 group=8 item=3 tray=120 base=940 wspad=18 ipad=8 tpad=12 tw=40
    elif [ "$w" -ge 1500 ]; then
        LAY_TIER=compact; gap=4 group=6 item=3 tray=96  base=850 wspad=14 ipad=6 tpad=8  tw=32
    else
        LAY_TIER=dense;   gap=4 group=6 item=6 tray=96  base=855 wspad=14 ipad=6 tpad=8  tw=24
    fi

    # Workspace buttons are the only variable-width part of the bar. Third field
    # counts *other* outputs — eww.yuck draws one detached card per output.
    read -r wsn wschars ndetached < <(
        i3-msg -t get_workspaces 2>/dev/null | jq -r --arg mon "$mon" '
            [.[] | .name | sub("^[0-9]+: *"; "")] as $l
            | "\($l | length) \($l | map(length) | add // 0) \(
                [.[] | .output] | unique | map(select(. != $mon)) | length)"
        ' 2>/dev/null
    )
    case "$wsn" in ''|*[!0-9]*) wsn=4 wschars=4 ndetached=0 ;; esac
    case "$ndetached" in ''|*[!0-9]*) ndetached=0 ;; esac

    wscost=$(( (wschars * CHAR100 + 50) / 100 + wsn * (wspad + 2) ))
    # Each detached card costs its own island padding plus WSMON for the marker
    # glyph (eww.scss `.wsmon`).
    wscost=$(( wscost + ndetached * (2 * ipad + gap + WSMON) ))

    # `tw` unless the output genuinely cannot fit it; the floor keeps the slot
    # readable even then (a few chars of overflow beat an unusable stub).
    LAY_TITLE=$(( ((w - base - wscost - MARGIN) * 100) / CHAR100 ))
    [ "$LAY_TITLE" -gt "$tw" ] && LAY_TITLE=$tw
    [ "$LAY_TITLE" -lt "$TITLE_MIN" ] && LAY_TITLE=$TITLE_MIN

    # Same slot in px for the title button's :width. `+ tpad` because eww's size
    # request covers padding too, while LAY_TITLE counts only the text.
    titlepx=$(( (LAY_TITLE * CHAR100 + 99) / 100 + tpad ))

    # Into OUT, not stdout: `out=$(emit)` would discard the LAY_*/LAST_* state
    # emit_changed needs, since the subshell's assignments are lost.
    printf -v OUT '{"tier":"%s","mon":"%s","w":%s,"gap":%s,"group":%s,"item":%s,"title":%s,"titlepx":%s,"tray":%s}' \
        "$LAY_TIER" "$mon" "$w" "$gap" "$group" "$item" "$LAY_TITLE" "$titlepx" "$tray"
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
