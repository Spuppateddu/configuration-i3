#!/usr/bin/env bash
# The $mod+r window mode: resize and move a floating window, resize a tiled one
# the way i3 does. hjkl pushes an edge out, HJKL pulls the same edge in, and the
# arrow keys move the whole window without changing its size.
#
# Growing and moving stop at the usable workspace — the rect i3 has already
# shrunk by the bar's strut — so a floating window can never end up off the
# monitor. Shrinking is never blocked, down to MIN_W x MIN_H.
#
# Never reloads i3. A reload re-arms every `for_window` rule — i3 forgets it
# already ran them — so the catch-all one re-floats each window at its next
# title change. Hence a border set at runtime as the mode cue, not a recoloured
# one, which i3 can only change by re-reading its config.
#   on -> pick the mode + thicken           |  off -> restore + leave
#   grow|shrink <dir> -> one edge step      |  clear -> at i3 start
#   move <dir> -> one step, size unchanged
set -eu

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/runtime_lib.sh" || exit 1

# Holds "<con_id> <style> <width>" while the mode is on: the border to put back,
# read from the window itself, so it survives an i3 restart mid-mode.
STATE="$(i3rc_runtime_dir)/i3rc-window-mode.state"

# Border width the mode switches to. `pixel` drops the title bar too, so the
# frame reads as "this window is armed" from across the screen.
MODE_BORDER_PX=${I3RC_MODE_BORDER_PX:-6}

# Pixels one keypress moves an edge, and the smallest frame a window can shrink
# to — below that a window is a stub you can no longer aim at with the mouse.
STEP_PX=${I3RC_MODE_STEP_PX:-20}
MIN_W=${I3RC_MODE_MIN_W:-120}
MIN_H=${I3RC_MODE_MIN_H:-80}

JQ_DESC='def desc: recurse(.nodes[]?, .floating_nodes[]?);'

# "<con_id> <floating> <border-style> <border-width>" for the focused window.
focused_border() {
    i3-msg -t get_tree | jq -r "$JQ_DESC"'
        [ desc | select(.focused == true)
        | "\(.id) \(.floating) \(.border) \(.current_border_width)" ] | first // empty'
}

# "<ws-x> <ws-y> <ws-w> <ws-h> <frame-x> <frame-y> <frame-w> <frame-h>" for con
# $1. The floating_con rect, not the window's: that is the frame `resize set`
# and `move position` speak in. Prints nothing when the window is not floating.
frame_of() {
    i3-msg -t get_tree | jq -r --argjson id "$1" "$JQ_DESC"'
        [ desc | select(.type == "workspace")
               | select([desc | select(.id == $id)] | length > 0)
               | { w: .rect,
                   f: ([ desc | select(.type == "floating_con")
                              | select([desc | select(.id == $id)] | length > 0)
                              | .rect ] | first) } ]
        | first // empty
        | select(.f != null)
        | "\(.w.x) \(.w.y) \(.w.width) \(.w.height) \(.f.x) \(.f.y) \(.f.width) \(.f.height)"'
}

# Con id the mode is working on: the one it thickened, so the keys and the fat
# border can never end up on two different windows.
mode_target() {
    local id=""
    [ -s "$STATE" ] && read -r id _ _ < "$STATE"
    [ -n "$id" ] || id=$(i3-msg -t get_tree | jq -r "$JQ_DESC"'
        [ desc | select(.focused == true) | .id ] | first // empty')
    printf '%s\n' "$id"
}

# Frame in, frame out. Changing the border style makes i3 keep the *client*
# size, so the frame grows or shrinks by a title bar — enough for a window
# sized to the screen edge to end up past it. Pinning the frame across the
# change is what keeps "never off the monitor" true after the mode exits.
apply_frame() {
    i3-msg "[con_id=$1] resize set $4 px $5 px; [con_id=$1] move position $2 px $3 px" >/dev/null
}

# Put a window's own border back. Unknown ids just fail the criteria match, so a
# window closed while the mode was on costs nothing.
restore() {
    local id=$1 style=$2 width=$3
    case $style in
        none) i3-msg "[con_id=$id] border none" >/dev/null ;;
        *)    i3-msg "[con_id=$id] border $style $width" >/dev/null ;;
    esac
}

# One step. $1 grow|shrink|move, $2 left|right|up|down. grow and shrink move
# exactly one edge — the opposite one only follows when the frame hits its
# minimum; move carries both edges and keeps the size.
step() {
    local how=$1 dir=$2 id wx wy ww wh x y w h nx ny nw nh
    id=$(mode_target); [ -n "$id" ] || return 0
    read -r wx wy ww wh x y w h < <(frame_of "$id") || return 0
    [ -n "${h:-}" ] || return 0
    nx=$x ny=$y nw=$w nh=$h

    case "$how $dir" in
        # Growing clamps on the workspace edge, so an edge already off-screen
        # comes back to it instead of running further out.
        "grow left")   nx=$(( x - STEP_PX < wx ? wx : x - STEP_PX )); nw=$(( w + x - nx )) ;;
        "grow up")     ny=$(( y - STEP_PX < wy ? wy : y - STEP_PX )); nh=$(( h + y - ny )) ;;
        "grow right")  nw=$(( w + STEP_PX > wx + ww - x ? wx + ww - x : w + STEP_PX )) ;;
        "grow down")   nh=$(( h + STEP_PX > wy + wh - y ? wy + wh - y : h + STEP_PX )) ;;
        # Shrinking pulls the same edge in: `left` walks the left edge right, so
        # the window loses width on its left side and the right edge stays put.
        "shrink left")  nw=$(( w - STEP_PX < MIN_W ? MIN_W : w - STEP_PX )); nx=$(( x + w - nw )) ;;
        "shrink up")    nh=$(( h - STEP_PX < MIN_H ? MIN_H : h - STEP_PX )); ny=$(( y + h - nh )) ;;
        "shrink right") nw=$(( w - STEP_PX < MIN_W ? MIN_W : w - STEP_PX )) ;;
        "shrink down")  nh=$(( h - STEP_PX < MIN_H ? MIN_H : h - STEP_PX )) ;;
        # Moving keeps the size and clamps on the workspace, so the window
        # stops flush against the screen edge instead of walking off it. The
        # second clamp is for a window wider or taller than the workspace: it
        # pins to the top-left corner rather than jumping backwards.
        "move left")   nx=$(( x - STEP_PX < wx ? wx : x - STEP_PX )) ;;
        "move up")     ny=$(( y - STEP_PX < wy ? wy : y - STEP_PX )) ;;
        "move right")  nx=$(( x + STEP_PX + w > wx + ww ? wx + ww - w : x + STEP_PX ))
                       nx=$(( nx < wx ? wx : nx )) ;;
        "move down")   ny=$(( y + STEP_PX + h > wy + wh ? wy + wh - h : y + STEP_PX ))
                       ny=$(( ny < wy ? wy : ny )) ;;
        *) echo "usage: ${0##*/} grow|shrink|move left|right|up|down" >&2; exit 2 ;;
    esac

    # Already against the edge: no IPC at all, so holding a key down at the
    # screen border costs nothing.
    [ "$nx $ny $nw $nh" != "$x $y $w $h" ] || return 0

    # A plain move needs no resize at all. Otherwise two commands, one round
    # trip, resize first: `move position` on the old size would land the frame
    # wrong for every grow that moves an edge.
    if [ "$nw $nh" = "$w $h" ]; then
        i3-msg "[con_id=$id] move position $nx px $ny px" >/dev/null
    else
        i3-msg "[con_id=$id] resize set $nw px $nh px; [con_id=$id] move position $nx px $ny px" >/dev/null
    fi
}

case "${1:-off}" in
    on)
        read -r id floating style width < <(focused_border) || exit 0
        [ -n "${width:-}" ] || exit 0

        # A floating window owns its four edges and its position, so hjkl can
        # push the edges around and the arrows can move it; a tiled one only
        # has a share of a split, which is i3's own resize mode.
        case $floating in
            user_on|auto_on) mode="resize floating" ;;
            *)               mode="resize" ;;
        esac

        printf '%s %s %s\n' "$id" "$style" "$width" > "$STATE"
        read -r _ _ _ _ fx fy fw fh < <(frame_of "$id") || true
        i3-msg "[con_id=$id] border pixel $MODE_BORDER_PX" >/dev/null
        [ -n "${fh:-}" ] && apply_frame "$id" "$fx" "$fy" "$fw" "$fh"
        i3-msg "mode \"$mode\"" >/dev/null
        ;;
    off)
        if [ -s "$STATE" ]; then
            read -r id style width < "$STATE"
            read -r _ _ _ _ fx fy fw fh < <(frame_of "$id") || true
            restore "$id" "$style" "$width"
            [ -n "${fh:-}" ] && apply_frame "$id" "$fx" "$fy" "$fw" "$fh"
        fi
        : > "$STATE"
        i3-msg "mode default" >/dev/null
        ;;
    grow|shrink|move)
        step "$1" "${2:?usage: ${0##*/} $1 left|right|up|down}"
        ;;
    clear)
        # i3-start form: put back a border left thick by a crash or by an i3
        # restart while the mode was on. No mode to leave at this point.
        if [ -s "$STATE" ]; then
            read -r id style width < "$STATE"
            restore "$id" "$style" "$width"
            : > "$STATE"
        fi
        ;;
    *)
        echo "usage: ${0##*/} on|off|clear|grow <dir>|shrink <dir>|move <dir>" >&2
        exit 2
        ;;
esac
