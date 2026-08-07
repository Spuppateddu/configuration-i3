#!/usr/bin/env bash
# Default sink volume as JSON (deflisten); "scroll up|down" adjusts the level.

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/scripts/emit_lib.sh" || exit 1   # resubscribe_loop

# One `wpctl` line carries both fields: "Volume: 0.30 [MUTED]". wpctl, not
# pactl — it reads back the same sink the setters below write. `10#`: "05".
emit() {
    local line vol int frac lvl=0 mut=false
    line=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)
    case "$line" in *"[MUTED]"*) mut=true ;; esac
    vol=${line#*Volume: }
    vol=${vol%% *}
    case "$vol" in
        [0-9]*.[0-9]*)
            int=${vol%%.*}
            frac=${vol#*.}00
            lvl=$(( 10#$int * 100 + 10#${frac:0:2} ))
            ;;
    esac
    printf '{"level":%s,"muted":%s}\n' "$lvl" "$mut"
}

# `-l 1.5` is the same cap XF86AudioRaiseVolume uses in `config` — pactl has no
# ceiling at all and would walk the sink arbitrarily far into software boost.
if [ "$1" = "scroll" ]; then
    if [ "$2" = "up" ]; then
        wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 3%+
    else
        wpctl set-volume @DEFAULT_AUDIO_SINK@ 3%-
    fi
    exit 0
fi

# The trailing `#` is load-bearing: pactl also emits `on sink-input #N`, one per
# stream, so a plain "on sink" match re-ran emit for every browser tab.
events() { pactl subscribe | grep --line-buffered -E "on sink #"; }

# Reconnects on its own — a PipeWire/Pulse restart ends `pactl subscribe`, and
# eww never respawns a deflisten that exited. See scripts/emit_lib.sh.
resubscribe_loop "" emit events
