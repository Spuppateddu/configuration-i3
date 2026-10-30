#!/usr/bin/env bash
# `focus_dir.sh <left|right|up|down>`: i3's own focus walks floating windows in
# list order, blind to where they sit. This picks the nearest one on screen.

# Floating: every visible window on every monitor, compared by centre; nothing
# that way means focus stays put (a wall). Tiled: plain i3 focus.

set -u

dir="${1:-}"
[[ "$dir" =~ ^(left|right|up|down)$ ]] || { echo "usage: $0 left|right|up|down" >&2; exit 2; }

SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Two centres are level on an axis when closer than this percent of the smaller
# window there (at least LEVEL_PX). Level on both: a pile, stepped by con id.
LEVEL_PCT=${I3RC_FOCUS_LEVEL_PCT:-10}
LEVEL_PX=${I3RC_FOCUS_LEVEL_PX:-20}

# How much a step sideways costs against a step forward. Windows sharing a row
# (for left/right) or a column (for up/down) pay nothing sideways.
SIDE_WEIGHT=${I3RC_FOCUS_SIDE_WEIGHT:-2}

JQ_DESC='def desc: recurse(.nodes[]?, .floating_nodes[]?);'

# Reads the tree on stdin, prints "native", or the con id to focus, or nothing.
# $vis: the names of the workspaces on screen, one per monitor.
JQ_PICK="$JQ_DESC"'
def win: desc | select(.window != null and (.nodes | length) == 0);
def mid: { x: (.rect.x + .rect.width / 2), y: (.rect.y + .rect.height / 2) };
# Forward axis and side axis for the direction, and the sign of "forward".
def axes: if $dir == "left" or $dir == "right" then ["x", "y", "width", "height"]
          else ["y", "x", "height", "width"] end;
def sign: if $dir == "left" or $dir == "up" then -1 else 1 end;

[desc | select(.type == "workspace")] as $wss
| ([$wss[] | select([win | select(.focused)] | length > 0)] | first) as $ws
| (if $ws == null then null else [$ws | win | select(.focused)] | first end) as $cur
| if $cur == null or ($cur.floating | test("_on$") | not) then "native"
  else
    axes as [$f, $s, $fl, $sl]
    | ($cur | mid) as $c
    | [ $wss[] | select(.name as $n | $vis | index($n)) | win | select(.id != $cur.id)
        | (mid) as $m
        | ((($m[$f] - $c[$f]) * sign)) as $fwd
        | (($m[$s] - $c[$s]) | fabs) as $side
        # Rows overlap on the side axis: no sideways cost.
        | (if .rect[$s] < $cur.rect[$s] + $cur.rect[$sl]
              and $cur.rect[$s] < .rect[$s] + .rect[$sl] then 0 else $side end) as $cost
        | ([$lvl, ([.rect[$fl], $cur.rect[$fl]] | min) * $pct / 100] | max) as $lf
        | ([$lvl, ([.rect[$sl], $cur.rect[$sl]] | min) * $pct / 100] | max) as $ls
        # Ahead means in the same row, or else inside the 45 degree cone.
        | if $fwd > $lf and ($cost == 0 or $fwd >= $side)
          then { id, m: $m, rect, score: ($fwd + $sw * $cost) }
          elif ($fwd | fabs) <= $lf and $side <= $ls
               and ((.id - $cur.id) * sign) > 0
          # Same pile: the next con id that way, before anything farther off.
          then { id, m: $m, rect, score: (-1e9 + ((.id - $cur.id) | fabs)) }
          else empty end ] as $cands
    | ($cands | min_by(.score)) as $best
    | if $best == null then empty
      # Landing on a pile: enter it at its first con id that way, so the next
      # presses walk all of it.
      else [ $cands[] | select(((.m.x - $best.m.x) | fabs)
                    <= ([$lvl, ([.rect.width, $best.rect.width] | min) * $pct / 100] | max)
                and ((.m.y - $best.m.y) | fabs)
                    <= ([$lvl, ([.rect.height, $best.rect.height] | min) * $pct / 100] | max)) ]
           | min_by(.id * sign) | .id
      end
  end'

vis="$(i3-msg -t get_workspaces | jq -c '[.[] | select(.visible) | .name]')"
pick="$(i3-msg -t get_tree | jq -r --arg dir "$dir" --argjson vis "$vis" \
    --argjson lvl "$LEVEL_PX" --argjson pct "$LEVEL_PCT" --argjson sw "$SIDE_WEIGHT" "$JQ_PICK")"

case "$pick" in
    native) i3-msg -q "focus $dir" ;;
    "")     exit 0 ;;
    *)      i3-msg -q "[con_id=$pick] focus" ;;
esac
"$SCRIPTS/warp_pointer.sh"
