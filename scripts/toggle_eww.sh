#!/usr/bin/env bash
# Toggle the eww bar on the primary output. Reuses launch_eww's output logic.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/eww_lib.sh" || exit 1   # EWW, CFG, eww_bar_is_open, eww_open_bar

# Fixed window id. Deriving it from the current primary output missed the
# running bar whenever that output had changed since the bar was opened, so the
# toggle opened a second bar on top of the first instead of closing it.
if eww_bar_is_open; then
    "$EWW" --config "$CFG" close bar
    rm -f "$BAR_SCREEN_STATE"   # no bar, so nothing is "current" any more
else
    eww_open_bar
fi
