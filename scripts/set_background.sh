#!/usr/bin/env bash
# Paint the root window a solid Gruvbox-dark colour (no wallpaper).
#
# xsetroot -solid does NOT work under picom: it draws the _XROOTPMAP_ID pixmap,
# which only feh updates. feh has no solid mode, hence the tiny tiled image.
set -euo pipefail

# Gruvbox Material Dark background #1d2021 -> RGB bytes 29,32,33 (matches theme.sh).
img="$HOME/.cache/i3-bg.ppm"
{ printf 'P6\n16 16\n255\n'; for _ in $(seq 1 256); do printf '\x1d\x20\x21'; done; } > "$img"

# --no-fehbg: don't write ~/.fehbg (we set this from i3 on every reload anyway).
exec feh --no-fehbg --bg-tile "$img"
