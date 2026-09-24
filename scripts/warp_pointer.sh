#!/usr/bin/env bash
# Puts the pointer in the middle of the focused window (or empty workspace).
# Run after each keyboard focus change, so focus_follows_mouse cannot undo it.

set -u

JQ_DESC='def desc: recurse(.nodes[]?, .floating_nodes[]?);'

rect="$(i3-msg -t get_tree | jq -r "$JQ_DESC"'
    [desc | select(.focused)][0].rect // empty | "\(.x) \(.y) \(.width) \(.height)"')"
[[ -n "$rect" ]] || exit 0
read -r x y w h <<<"$rect"
xdotool mousemove "$((x + w / 2))" "$((y + h / 2))"
