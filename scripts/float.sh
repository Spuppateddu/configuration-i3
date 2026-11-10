#!/usr/bin/env bash
# The floating desktop: `watch` sizes every new window and drops it on a random
# free spot that keeps the window you came from readable, `move <dir>` snaps a
# floating one, `place <con_id>` places one on demand (desktop_mode.sh),
# `send <ws>` moves the focused one to a workspace, refitted to its monitor.

# Every number comes from the live workspace rect, which i3 already shrank by the
# eww bar's strut — so no resolution, bar height or output name is hardcoded.

set -u

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/runtime_lib.sh" || exit 1

PIDFILE="$(i3rc_runtime_dir)/i3rc-float.pid"

# Standard window: percent of the usable workspace — a tall rectangle, 45% wide
# so two still sit side by side, 98% high and centred, with an even margin
# above and below.
# Every new normal window opens at this size, centred; it is also a rung of
# the `move up` / `move down` ladder below.
STD_W_PCT=${I3RC_STD_W_PCT:-45}
STD_H_PCT=${I3RC_STD_H_PCT:-98}

# The ladder, `move up` one rung bigger, `move down` one smaller, stopping at
# the ends: full -> tall (STD) -> square -> box. The square's side in percent
# of the short edge.
SQUARE_PCT=${I3RC_SQUARE_PCT:-60}

# The box, the smallest rung: always 16:9, its width in percent of the usable
# workspace, its height from that width.
BOX_W_PCT=${I3RC_BOX_W_PCT:-40}

# The full shape, the top rung: percent of the usable workspace, centred. 100 is the whole screen below the bar — still a floating
# window, not i3's fullscreen, so the bar stays in view.
VMAX_W_PCT=${I3RC_VMAX_W_PCT:-100}
VMAX_H_PCT=${I3RC_VMAX_H_PCT:-100}

# Spots a new window may be dropped on, across the usable workspace and down it.
# 1 row keeps every window vertically centred; 1 x 1 is the centre alone.
PLACE_COLS=${I3RC_PLACE_COLS:-9}
PLACE_ROWS=${I3RC_PLACE_ROWS:-1}

# How much of the window you were just on a new window may hide, in percent of
# its area. Every spot under this counts as free and can be drawn; 0 means only
# spots that hide nothing of it at all.
MAX_COVER_PCT=${I3RC_MAX_COVER_PCT:-25}

# Breathing room a new window keeps from the edges of the usable workspace, in
# pixels: no frame is ever flush against a screen edge or the bar. Shrunk on the
# spot if a window is too big to fit with it, so a slot always exists.
EDGE_GAP_PX=${I3RC_EDGE_GAP_PX:-16}

# Classes the daemon never resizes: their window *is* the screen, so a
# standard-size frame breaks them outright.
SKIP_CLASS_RE=${I3RC_FLOAT_SKIP:-'^(flameshot|i3lock)$'}

# jq's tree walk. floating_nodes too, or every floating window is invisible here.
JQ_DESC='def desc: recurse(.nodes[]?, .floating_nodes[]?);'

# Prints "<state> <x> <y> <w> <h>" for the focused window: its floating state
# and the rect of the workspace it is on.
focused_state() {
    i3-msg -t get_tree | jq -r "$JQ_DESC"'
        [ desc | select(.type == "workspace")
               | select([desc | select(.focused == true)] | length > 0)
               | { r: .rect,
                   f: ([desc | select(.focused == true) | .floating] | first) } ]
        | first // empty
        | "\(.f) \(.r.x) \(.r.y) \(.r.width) \(.r.height)"'
}

# "<floating> <window-type> <x> <y> <w> <h>" for con $1: its state as it is
# *now*, plus its workspace rect — a window can open on an unfocused workspace.
con_state_of() {
    i3-msg -t get_tree | jq -r --argjson id "$1" "$JQ_DESC"'
        [ desc | select(.type == "workspace")
               | select([desc | select(.id == $id)] | length > 0)
               | { r: .rect, c: ([desc | select(.id == $id)] | first) } ]
        | first // empty
        | "\(.c.floating) \(.c.window_type // "normal") \(.r.x) \(.r.y) \(.r.width) \(.r.height)"'
}

# "<x> <y> <w> <h> <prev>" per floating window already on con $1's workspace,
# that one left out. The floating con carries the frame rect, which is what
# `move position` sets and what the new window would cover.
#
# <prev> is 1 on the window that was focused before this one opened: i3 keeps a
# workspace's children in focus order, so it is simply the first one that is not
# us — no state to remember between events, and it works from desktop_mode.sh
# too. It is 0 on every window when the previous one was tiled or is gone.
peers_of() {
    i3-msg -t get_tree | jq -r --argjson id "$1" "$JQ_DESC"'
        [ desc | select(.type == "workspace")
               | select([desc | select(.id == $id)] | length > 0) ]
        | first // empty
        | . as $ws
        | ([ $ws.floating_nodes[]
             | select([desc | select(.id == $id)] | length > 0)
             | .id ] | first) as $self
        | ([ $ws.focus[]? | select(. != $self) ] | first) as $prev
        | $ws.floating_nodes[]
        | select(.id != $self)
        | "\(.rect.x) \(.rect.y) \(.rect.width) \(.rect.height) \(if .id == $prev then 1 else 0 end)"'
}

# "<n> <lo> <hi> <mid>" in, n candidate positions out: evenly spaced from <lo>
# to <hi>, both included. n of 1, or no room to move at all, is <mid> alone.
slots() {
    local n=$1 lo=$2 hi=$3 mid=$4 i
    if ! [ "$n" -gt 1 ] 2>/dev/null || [ "$hi" -le "$lo" ]; then
        printf '%d\n' "$mid"
        return 0
    fi
    for ((i = 0; i < n; i++)); do
        printf '%d\n' "$((lo + i * (hi - lo) / (n - 1)))"
    done
}

# "<con> <W> <H> <X> <Y> <ws-x> <ws-y> <ws-w> <ws-h>" in, a spot "<X> <Y>" out.
#
# Nothing else open: the centre. Otherwise a *random* spot that keeps the window
# you were just on in sight — every slot is measured by how much of that window
# the new frame would hide there, every slot hiding no more than MAX_COVER_PCT of
# it is fair game, and one of those is drawn. Random on purpose: two windows
# opened one after the other should not land in the same place, and the screen
# fills up evenly instead of always from the same corner.
#
# When even the best slot hides more than MAX_COVER_PCT — a screen with no room
# left — the draw is made among the least-hiding slots instead, so the rule
# degrades quietly rather than piling every window in one spot.
#
# Slots that leave the *other* windows untouched as well are preferred whenever
# there are any: free screen is used before anything is buried. Slots stay
# EDGE_GAP_PX inside the workspace, so nothing ever opens flush against an edge.
free_spot() {
    local id=$1 w=$2 h=$3 cx=$4 cy=$5 x=$6 y=$7 ww=$8 wh=$9
    local -a px=() py=() pw=() ph=() cols=() rows=()
    local -a slot_x=() slot_y=() hid=() other=() pick=() clean=()
    local a b c d f i sx sy gx gy ox oy area
    local prev=-1 ref_area=0 best=-1 limit thr

    while read -r a b c d f; do
        [ -n "${f:-}" ] || continue
        px+=("$a"); py+=("$b"); pw+=("$c"); ph+=("$d")
        [ "$f" = 1 ] && prev=$((${#px[@]} - 1))
    done < <(peers_of "$id")

    # An empty workspace gets the centre, and that is the whole rule for it.
    [ "${#px[@]}" -gt 0 ] || { printf '%d %d\n' "$cx" "$cy"; return 0; }

    # What "in sight" is measured against: the window you were just on, or, when
    # that one is gone or tiled, every window on the workspace together.
    if [ "$prev" -ge 0 ]; then
        ref_area=$((pw[prev] * ph[prev]))
    else
        for i in "${!px[@]}"; do ref_area=$((ref_area + pw[i] * ph[i])); done
    fi
    limit=$((ref_area * MAX_COVER_PCT / 100))

    # The edge gap, per axis, never more than half of what the window leaves
    # free: a window with no room to spare keeps its centred position instead.
    gx=$EDGE_GAP_PX; gy=$EDGE_GAP_PX
    [ $((ww - w)) -lt $((2 * gx)) ] && gx=$(((ww - w) / 2))
    [ $((wh - h)) -lt $((2 * gy)) ] && gy=$(((wh - h) / 2))
    [ "$gx" -lt 0 ] && gx=0
    [ "$gy" -lt 0 ] && gy=0

    mapfile -t cols < <(slots "$PLACE_COLS" "$((x + gx))" "$((x + ww - w - gx))" "$cx")
    mapfile -t rows < <(slots "$PLACE_ROWS" "$((y + gy))" "$((y + wh - h - gy))" "$cy")

    # Pass one: for every slot, how much of the reference window it would hide,
    # and how much of everything else.
    for sx in "${cols[@]}"; do
        for sy in "${rows[@]}"; do
            slot_x+=("$sx"); slot_y+=("$sy"); hid+=(0); other+=(0)
            for i in "${!px[@]}"; do
                # Overlap of two rectangles: the gap between the inner edges on
                # each axis, and nothing at all as soon as one of them is empty.
                ox=$(( (sx + w < px[i] + pw[i] ? sx + w : px[i] + pw[i])
                       - (sx > px[i] ? sx : px[i]) ))
                [ "$ox" -gt 0 ] || continue
                oy=$(( (sy + h < py[i] + ph[i] ? sy + h : py[i] + ph[i])
                       - (sy > py[i] ? sy : py[i]) ))
                [ "$oy" -gt 0 ] || continue
                area=$((ox * oy))
                if [ "$prev" -lt 0 ] || [ "$i" = "$prev" ]; then
                    hid[-1]=$((hid[-1] + area))
                else
                    other[-1]=$((other[-1] + area))
                fi
            done
            [ "$best" -lt 0 ] || [ "${hid[-1]}" -lt "$best" ] && best=${hid[-1]}
        done
    done

    # Pass two: everything at or under the threshold goes in the hat, and the
    # slots that bury nothing else at all get the hat to themselves if they exist.
    thr=$((best > limit ? best : limit))
    for i in "${!slot_x[@]}"; do
        [ "${hid[i]}" -le "$thr" ] || continue
        pick+=("$i")
        [ "${other[i]}" = 0 ] && clean+=("$i")
    done
    [ "${#clean[@]}" -gt 0 ] && pick=("${clean[@]}")

    i=${pick[RANDOM % ${#pick[@]}]}
    printf '%d %d\n' "${slot_x[i]}" "${slot_y[i]}"
}

# "down <x> <y> <w> <h>" in, "<W> <H> <X> <Y>" out: the standard size, centred.
target() {
    local dir=$1 x=$2 y=$3 w=$4 h=$5 tw th
    case $dir in
        down)
            tw=$((w * STD_W_PCT / 100)); th=$((h * STD_H_PCT / 100))
            printf '%d %d %d %d\n' "$tw" "$th" "$((x + (w - tw) / 2))" "$((y + (h - th) / 2))" ;;
        *) return 1 ;;
    esac
}

# $1 criteria, then W H X Y. Two separate commands on purpose: comma-chained,
# i3 re-centres the window on its old size and the position lands nowhere near.
apply() {
    i3-msg "[$1] resize set $2 px $3 px; [$1] move position $4 px $5 px" >/dev/null
}

# The window is already mapped by the time either caller runs, so `resize set`
# means the whole frame — title bar included, no correction needed.
cmd_move() {
    local dir=$1 state x y w h
    read -r state x y w h < <(focused_state) || return 0
    [ -n "${h:-}" ] || return 0
    case $state in
        user_on|auto_on)
            if [ "$dir" = down ] || [ "$dir" = up ]; then
                set_shape "$dir"
            else
                slide "$dir"
            fi ;;
        *) i3-msg "move $dir" >/dev/null ;;
    esac
}

# "<pos> <size> <ws-start> <ws-size>" in, a start that keeps the frame inside
# the workspace out, EDGE_GAP_PX from its edges when there is room for that.
clamp() {
    local p=$1 s=$2 lo=$3 n=$4 g=$EDGE_GAP_PX hi
    [ $((n - s)) -lt $((2 * g)) ] && g=$(((n - s) / 2))
    [ "$g" -lt 0 ] && g=0
    hi=$((lo + n - s - g)); lo=$((lo + g))
    [ "$p" -gt "$hi" ] && p=$hi
    [ "$p" -lt "$lo" ] && p=$lo
    printf '%d\n' "$p"
}

# $1 left|right: one stop that way, left edge -> centre -> right edge, at the
# window's own size; at the edge already, that half of the screen. 2px slack.
slide() {
    local dir=$1 con x y w h fx fy fw fh to p
    read -r con _ x y w h fx fy fw fh < <(focused_frame) || return 0
    [ -n "${fh:-}" ] || return 0
    local -a stops=("$(clamp "$x" "$fw" "$x" "$w")"
                    "$(clamp "$((x + (w - fw) / 2))" "$fw" "$x" "$w")"
                    "$(clamp "$((x + w))" "$fw" "$x" "$w")")
    # Past an edge stop (a half sits flush) counts as on it, so no 16px nudge.
    [ "$fx" -lt "${stops[0]}" ] && fx=${stops[0]}
    [ "$fx" -gt "${stops[2]}" ] && fx=${stops[2]}
    if [ "$dir" = left ]; then
        if [ "$fx" -le $((stops[0] + 2)) ]; then
            apply "con_id=$con" "$((w / 2))" "$h" "$x" "$y"; return
        fi
        to=${stops[0]}
        for p in "${stops[@]}"; do [ "$p" -lt $((fx - 2)) ] && to=$p; done
    else
        if [ "$fx" -ge $((stops[2] - 2)) ]; then
            apply "con_id=$con" "$((w - w / 2))" "$h" "$((x + w / 2))" "$y"; return
        fi
        to=${stops[2]}
        for p in "${stops[2]}" "${stops[1]}" "${stops[0]}"; do
            [ "$p" -gt $((fx + 2)) ] && to=$p
        done
    fi
    i3-msg "[con_id=$con] move position $to px $fy px" >/dev/null
}

# $1 up|down: one rung up or down full -> tall -> square -> box, centred
# vertically, left edge kept. Stops at the ends; any other shape gets tall (up) or square (down).
set_shape() {
    local dir=$1 con x y w h fx fy fw fh side i dw dh tw th next cur=-1
    local s_con s_i s_w s_h state
    local -a sw sh
    state="$(i3rc_runtime_dir)/i3rc-ladder"
    read -r con _ x y w h fx fy fw fh < <(focused_frame) || return 0
    [ -n "${fh:-}" ] || return 0
    side=$(( (w < h ? w : h) * SQUARE_PCT / 100 ))
    # Rungs, biggest first: 0 full, 1 tall, 2 square, 3 box.
    sw=("$((w * VMAX_W_PCT / 100))" "$((w * STD_W_PCT / 100))" "$side" "$((w * BOX_W_PCT / 100))")
    sh=("$((h * VMAX_H_PCT / 100))" "$((h * STD_H_PCT / 100))" "$side" "$((w * BOX_W_PCT * 9 / 1600))")

    # 3% slack: a terminal snaps its size to whole cells, so it rarely lands exact.
    for ((i = 0; i < 4; i++)); do
        dw=$((fw - sw[i])); dh=$((fh - sh[i]))
        if [ "${dw#-}" -le $((w * 3 / 100)) ] && [ "${dh#-}" -le $((h * 3 / 100)) ]; then
            cur=$i; break
        fi
    done
    # A min size (Firefox: 500px wide) can block a shape: the last one we set
    # still counts while the frame is the size it really took.
    read -r s_con s_i s_w s_h 2>/dev/null < "$state"
    if [ "${s_con:-}" = "$con" ] && [ "${s_w:-}" = "$fw" ] && [ "${s_h:-}" = "$fh" ]; then
        cur=$s_i
    fi

    if [ "$cur" -lt 0 ]; then
        if [ "$dir" = up ]; then next=1; else next=2; fi
    elif [ "$dir" = up ]; then
        next=$((cur > 0 ? cur - 1 : 0))
    else
        next=$((cur < 3 ? cur + 1 : 3))
    fi

    tw=${sw[next]}; th=${sh[next]}
    i3-msg "[con_id=$con] resize set $tw px $th px" >/dev/null
    # Keep the window's left edge where it was (pulled back inside the workspace
    # if the new width runs past an edge) and centre it vertically. Read the
    # size it really took, so a refused shrink lands right.
    read -r _ _ tw th < <(frame_of "$con")
    apply "con_id=$con" "$tw" "$th" \
          "$(clamp "$fx" "$tw" "$x" "$w")" \
          "$(clamp "$((y + (h - th) / 2))" "$th" "$y" "$h")"
    printf '%s %d %s %s\n' "$con" "$next" "$tw" "$th" > "$state"
}

# "<con> <floating> <ws-x> <ws-y> <ws-w> <ws-h> <x> <y> <w> <h>" for the focused
# window: its con id, floating state, workspace rect and frame rect (the
# floating con's, or its own when tiled).
focused_frame() {
    i3-msg -t get_tree | jq -r "$JQ_DESC"'
        [ desc | select(.type == "workspace")
               | select([desc | select(.focused == true)] | length > 0)
               | . as $ws
               | ([desc | select(.focused == true)] | first) as $c
               | ([ $ws.floating_nodes[]
                    | select([desc | select(.focused == true)] | length > 0)
                    | .rect ] | first // $c.rect) as $f
               | "\($c.id) \($c.floating) \($ws.rect.x) \($ws.rect.y) \($ws.rect.width) \($ws.rect.height) \($f.x) \($f.y) \($f.width) \($f.height)" ]
        | first // empty'
}

# "<x> <y> <w> <h>" of con $1's frame: its floating con's rect.
frame_of() {
    i3-msg -t get_tree | jq -r --argjson id "$1" "$JQ_DESC"'
        [ desc | select(.type == "floating_con")
               | select([desc | select(.id == $id)] | length > 0) | .rect ]
        | first // empty | "\(.x) \(.y) \(.width) \(.height)"'
}

# Waits up to a second for con $1's frame to hold still. An app that scales
# itself per monitor DPI (alacritty) resizes its own window after the move.
settle() {
    local prev="" cur i
    for ((i = 0; i < 20; i++)); do
        sleep 0.05
        cur=$(frame_of "$1")
        [ -n "$prev" ] && [ "$cur" = "$prev" ] && return 0
        prev=$cur
    done
}

# $mod+Shift+<n>: send the focused window to workspace $1 and follow it. A
# floating window keeps its share of the screen and its spot: i3 keeps its pixel
# size across monitors, and a DPI-aware app rescales itself on top. So once it
# has settled, the frame is always set again from the old share, never trusted.
cmd_send() {
    local ws=$1 id floating ox oy ow oh fx fy fw fh nx ny nw nh
    read -r id floating ox oy ow oh fx fy fw fh < <(focused_frame) || id=""
    i3-msg "move container to workspace number $ws" >/dev/null
    i3-msg "workspace number $ws" >/dev/null
    if [ -n "${fh:-}" ] && [ "$ow" -gt 0 ] && [ "$oh" -gt 0 ]; then
        case $floating in
            user_on|auto_on)
                settle "$id"
                read -r _ _ nx ny nw nh < <(con_state_of "$id") || nh=""
                [ -n "${nh:-}" ] &&
                    apply "con_id=$id" "$((fw * nw / ow))" "$((fh * nh / oh))" \
                          "$((nx + (fx - ox) * nw / ow))" "$((ny + (fy - oy) * nh / oh))" ;;
        esac
    fi
    "$(dirname -- "${BASH_SOURCE[0]}")/warp_pointer.sh"
}

# Standard size for con $1 if it is a normal window, centred as-is if it is a
# dialog. A tiled con is left alone: `resize set` there moves the split instead.
place_con() {
    local floating wt x y w h tw th tx ty
    read -r floating wt x y w h < <(con_state_of "$1") || return 0
    [ -n "${h:-}" ] || return 0
    case $floating in user_on|auto_on) ;; *) return 0 ;; esac

    if [ "$wt" = "normal" ]; then
        # The centred target is only the size and a fallback position: the scan
        # moves it to whichever slot hides the least of what is already open.
        read -r tw th tx ty < <(target down "$x" "$y" "$w" "$h")
        read -r tx ty < <(free_spot "$1" "$tw" "$th" "$tx" "$ty" \
                                    "$x" "$y" "$w" "$h")
        apply "con_id=$1" "$tw" "$th" "$tx" "$ty"
    else
        # Dialogs, pickers and splashes keep the size they asked for; only the
        # centring is ours, and unlike `move position center` it respects the bar.
        i3-msg "[con_id=$1] move position center" >/dev/null
    fi
}

# One window event in. The string test comes first so that the title changes a
# terminal emits on every command don't each cost a jq fork.
place() {
    local id floating fs class
    case $1 in *'"change":"new"'*) ;; *) return 0 ;; esac
    # Class is read last: it is the only field that can contain a space.
    read -r id floating fs class < <(printf '%s' "$1" | jq -r '
        select(.change == "new") | .container
        | "\(.id) \(.floating // "-") \(.fullscreen_mode // 0) \(.window_properties.class // "-")"')
    [ -n "${id:-}" ] || return 0
    [ "$fs" = "0" ] || return 0
    [[ $class =~ $SKIP_CLASS_RE ]] && return 0
    # Prefilter only: tiling mode tiles the window back a moment later, so
    # place_con re-reads the state instead of trusting this snapshot.
    case $floating in user_on|auto_on) ;; *) return 0 ;; esac

    place_con "$id"
}

# Same pidfile dance as restart_kbd.sh: exec_always re-runs us on every i3
# restart, and without this a hand-started copy would keep subscribing too.
is_self() {
    local me="${BASH_SOURCE[0]##*/}"
    i3rc_script_of_pid "$1" || return 1
    [ "${I3RC_SCRIPT##*/}" = "$me" ]
}

release_pidfile() {
    local cur
    [ -r "$PIDFILE" ] || return 0
    read -r cur <"$PIDFILE" || return 0
    [ "$cur" = "$$" ] && rm -f "$PIDFILE"
    return 0
}

cmd_watch() {
    local old ev sub_pid
    if [ -r "$PIDFILE" ]; then
        read -r old <"$PIDFILE" || old=""
        case $old in
            ''|*[!0-9]*|"$$") ;;
            *) is_self "$old" && kill "$old" 2>/dev/null ;;
        esac
    fi
    printf '%s\n' "$$" >"$PIDFILE"

    # Process substitution, not a pipeline: the read has to stay in *this* shell.
    # Behind a pipeline the trap below only fires once the stream ends — never.
    exec 3< <(i3-msg -t subscribe -m '[ "window" ]' 2>/dev/null)
    sub_pid=$!
    trap 'kill "$sub_pid" 2>/dev/null; release_pidfile' EXIT
    trap 'exit 0' TERM INT

    # No resubscribe loop: the stream only ends when i3 restarts, and that same
    # restart re-runs this script through exec_always.
    while read -r ev <&3; do
        place "$ev"
    done
}

case "${1:-}" in
    watch) cmd_watch ;;
    move)  cmd_move "${2:?usage: float.sh move <left|down|up|right>}" ;;
    place) place_con "${2:?usage: float.sh place <con_id>}" ;;
    send)  cmd_send "${2:?usage: float.sh send <workspace>}" ;;
    *)     printf 'usage: %s watch | move <left|down|up|right> | place <con_id> | send <workspace>\n' "${0##*/}" >&2; exit 2 ;;
esac
