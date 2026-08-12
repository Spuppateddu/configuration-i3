#!/usr/bin/env bash
# The floating desktop: `watch` is the daemon that sizes and centres every new
# window; `move <dir>` snaps a floating window but plain-`move`s a tiled one.

# Every number comes from the live workspace rect, which i3 already shrank by the
# eww bar's strut — so no resolution, bar height or output name is hardcoded.

set -u

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/runtime_lib.sh" || exit 1

PIDFILE="$(i3rc_runtime_dir)/i3rc-float.pid"

# Standard window: percent of the usable workspace, centred. Every new normal
# window opens like this, and `move down` snaps a window back to it.
STD_W_PCT=${I3RC_STD_W_PCT:-50}
STD_H_PCT=${I3RC_STD_H_PCT:-70}

# `move up`: percent of the usable workspace height a window grows to, keeping
# its own width. Not 100, so the frame still reads as a floating window.
VMAX_H_PCT=${I3RC_VMAX_H_PCT:-96}

# Classes the daemon never resizes: their window *is* the screen, so a
# standard-size frame breaks them outright.
SKIP_CLASS_RE=${I3RC_FLOAT_SKIP:-'^(flameshot|i3lock)$'}

# jq's tree walk. floating_nodes too, or every floating window is invisible here.
JQ_DESC='def desc: recurse(.nodes[]?, .floating_nodes[]?);'

# Prints "<state> <x> <y> <w> <h> <win-x> <win-w>" for the focused window: the
# workspace rect, then the window's own x/width — the column `move up` keeps.
focused_state() {
    i3-msg -t get_tree | jq -r "$JQ_DESC"'
        [ desc | select(.type == "workspace")
               | select([desc | select(.focused == true)] | length > 0)
               | { r: .rect,
                   f: ([desc | select(.focused == true) | .floating] | first),
                   w: ([desc | select(.focused == true) | .rect] | first) } ]
        | first // empty
        | "\(.f) \(.r.x) \(.r.y) \(.r.width) \(.r.height) \(.w.x) \(.w.width)"'
}

# Same rect, for a window the daemon was told about instead of the focused one:
# a window can open on a workspace that is not the focused one.
ws_rect_of() {
    i3-msg -t get_tree | jq -r --argjson id "$1" "$JQ_DESC"'
        [ desc | select(.type == "workspace")
               | select([desc | select(.id == $id)] | length > 0)
               | .rect ]
        | first // empty
        | "\(.x) \(.y) \(.width) \(.height)"'
}

# "<dir> <x> <y> <w> <h> [<win-x> <win-w>]" in, "<W> <H> <X> <Y>" out; only `up`
# reads the window rect. Integer division; `w - w/2` right half, so no 1px gap.
target() {
    local dir=$1 x=$2 y=$3 w=$4 h=$5 wx=${6:-$2} ww=${7:-$4} tw th
    case $dir in
        left)  printf '%d %d %d %d\n' "$((w / 2))" "$h" "$x" "$y" ;;
        right) printf '%d %d %d %d\n' "$((w - w / 2))" "$h" "$((x + w / 2))" "$y" ;;
        up)
            # Height only: the window keeps its own width and column, and stays
            # vertically centred so the leftover margin is split evenly.
            th=$((h * VMAX_H_PCT / 100))
            printf '%d %d %d %d\n' "$ww" "$th" "$wx" "$((y + (h - th) / 2))" ;;
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
    local dir=$1 state x y w h wx ww
    read -r state x y w h wx ww < <(focused_state) || return 0
    [ -n "${ww:-}" ] || return 0
    case $state in
        user_on|auto_on) apply con_id=__focused__ $(target "$dir" "$x" "$y" "$w" "$h" "$wx" "$ww") ;;
        *)               i3-msg "move $dir" >/dev/null ;;
    esac
}

# One window event in. The string test comes first so that the title changes a
# terminal emits on every command don't each cost a jq fork.
place() {
    local id wt floating fs class x y w h
    case $1 in *'"change":"new"'*) ;; *) return 0 ;; esac
    # Class is read last: it is the only field that can contain a space.
    read -r id wt floating fs class < <(printf '%s' "$1" | jq -r '
        select(.change == "new") | .container
        | "\(.id) \(.window_type // "-") \(.floating // "-") \(.fullscreen_mode // 0) \(.window_properties.class // "-")"')
    [ -n "${id:-}" ] || return 0
    [ "$fs" = "0" ] || return 0
    [[ $class =~ $SKIP_CLASS_RE ]] && return 0
    case $floating in user_on|auto_on) ;; *) return 0 ;; esac

    read -r x y w h < <(ws_rect_of "$id") || return 0
    [ -n "${h:-}" ] || return 0
    if [ "$wt" = "normal" ]; then
        apply "con_id=$id" $(target down "$x" "$y" "$w" "$h")
    else
        # Dialogs, pickers and splashes keep the size they asked for; only the
        # centring is ours, and unlike `move position center` it respects the bar.
        i3-msg "[con_id=$id] move position center" >/dev/null
    fi
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
    *)     printf 'usage: %s watch | move <left|down|up|right>\n' "${0##*/}" >&2; exit 2 ;;
esac
