#!/usr/bin/env bash
# Toggle the eww bar on every output it is configured for (bar_mode: all, or the
# primary alone). Reuses launch_eww's output logic.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/eww_lib.sh" || exit 1   # eww_bar_is_open, eww_close_bars, eww_open_bar

# Closed by the ids that are actually open, not by the ids the outputs ask for
# now: an output that changed since the bars went up would otherwise leave one
# behind, and the toggle would open a second bar on top of it.
if eww_bar_is_open; then
    eww_close_bars
else
    eww_open_bar
fi
