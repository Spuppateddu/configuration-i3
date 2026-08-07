#!/usr/bin/env bash
# Queue all tracks from a folder under MPD's music_directory and play (shuffled).
#
# Usage:
#   play_folder.sh                       # interactive rofi picker
#   play_folder.sh "Music-playlist"      # play a named subfolder
#   play_folder.sh ""                    # play the entire library
#
# Assumes mpd's music_directory is ~/Music (see INSTALL.md).

set -e

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MUSIC_ROOT="${MUSIC_ROOT:-$HOME/Music}"

# Folder names reach dunst, which parses notifications as Pango — an unescaped
# '&' ("Simon & Garfunkel") costs the notification its formatting.
source "$REPO/scripts/emit_lib.sh" || exit 1   # pango_escape

if ! command -v mpc >/dev/null 2>&1; then
    notify-send "Music" "mpc not installed — see INSTALL.md"
    exit 1
fi

# Branch on argument *count*: `folder="$1"` sets `folder` even with no $1, which
# made `${folder+x}` always true and the picker unreachable.
if [ $# -eq 0 ]; then
    # No argument at all: show rofi picker of top-level folders.
    folder=$(find "$MUSIC_ROOT" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort |
        rofi -dmenu -i -p "Play" -config "$REPO/rofi/config.rasi")
    [ -z "$folder" ] && exit 0
else
    folder="$1"
fi

# Insurance for what mpd's auto_update inotify misses (network mounts, watch
# limits). Not `--wait`, which would block $mod+Shift+m on a full rescan.
mpc -q update >/dev/null 2>&1 || true

# Resolve the folder *before* touching the queue: rofi -dmenu accepts free text,
# and clear-then-add on an unresolvable name wiped the queue and exited silently.
target=${folder:-/}
pango_escape shown "${folder:-/}"
if ! mpc ls "$target" >/dev/null 2>&1; then
    notify-send -i dialog-error "Music" "No such folder in the mpd library: $shown"
    exit 1
fi

mpc -q clear
mpc -q add "$target"
mpc -q random on
mpc -q consume off
mpc -q repeat on
mpc -q play

pango_escape shown "${folder:-entire library}"
notify-send -i media-playback-start "Music" "Playing: $shown (shuffled)"
