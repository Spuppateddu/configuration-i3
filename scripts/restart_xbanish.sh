#!/usr/bin/env bash
# Hide the mouse pointer while typing, restore it on mouse move/click.
#
# Started from i3 with `exec_always`, so kill any previous instance first —
# otherwise every i3 restart would stack another xbanish on the X connection.

command -v xbanish >/dev/null 2>&1 || exit 0

pkill -x xbanish 2>/dev/null

# -i shift -i control -i mod1 -i mod4
#   Don't hide on bare modifiers: those are chords ($mod+d, Ctrl+Shift+4, …)
#   that usually end in a click or in something you want to point at.
exec xbanish -i shift -i control -i mod1 -i mod4
