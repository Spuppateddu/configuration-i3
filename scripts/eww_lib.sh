#!/usr/bin/env bash
# Shared helpers for the eww bar launcher (launch_eww.sh), the toggle
# (toggle_eww.sh) and the layout emitter (eww/scripts/screen.sh).
# Sourced, not executed.

# Derived from this file's location, so a working copy uses its own siblings.
# The repo still has to live at ~/.i3rc — setup.sh installs nowhere else.
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
EWW="$HOME/.local/bin/eww"
CFG="$REPO/eww"

source "$REPO/scripts/runtime_lib.sh" || return 1   # i3rc_runtime_dir

# The output the running bar was opened on. launch_eww.sh compares it against
# the current primary to decide whether a restart has anything to rebuild.
BAR_SCREEN_STATE="$(i3rc_runtime_dir)/i3rc-eww-screen"

# Echo "<output> <width_px>" for the bar's monitor: primary, else first active.
# Empty during the cold-boot window, before any output is active.
#
# i3, not xrandr: `xrandr --listactivemonitors` re-probes the connectors (138ms
# vs 3ms), and i3's own view is what screen.sh's `output` events announce.
# `select(.active)` skips the synthetic xroot-0 spanning every monitor.
primary_output() {
    i3-msg -t get_outputs 2>/dev/null | jq -r '
        ([.[] | select(.active and .primary)] + [.[] | select(.active)])[0]
        | select(. != null)
        | "\(.name) \(.rect.width)"' 2>/dev/null
}

# Like primary_output, but waits out the cold-boot window — an empty answer
# there means `eww open --screen ""` fails and the bar never appears at all.
# Blocking, so startup paths only: on an event path it would stall the loop.
primary_output_wait() {
    local line i
    for ((i = 0; i < 30; i++)); do          # ~6s ceiling; usually resolves at once
        line=$(primary_output)
        [ -n "$line" ] && { printf '%s\n' "$line"; return 0; }
        sleep 0.2
    done
    return 1
}

# An eww `--screen` argument guaranteed to name a real monitor — the polled
# output, else index 0.
eww_screen() {
    local out
    read -r out _ < <(primary_output_wait)
    [ -n "$out" ] && { printf '%s\n' "$out"; return; }
    printf '0\n'                            # index 0 is always a valid screen
}

# True when a bar window is open on any output.
eww_bar_is_open() {
    "$EWW" --config "$CFG" active-windows 2>/dev/null | grep -q '^bar:'
}

# True when the bar is already up on the right output — a restart has nothing to
# rebuild. Non-blocking on purpose: no output yet means take the startup path.
eww_bar_is_current() {
    local want have
    eww_bar_is_open || return 1
    read -r want _ < <(primary_output)
    [ -n "$want" ] || return 1
    # Tested before opening: redirections apply left to right, so `<missing
    # 2>/dev/null` still prints the failure before stderr is silenced.
    [ -r "$BAR_SCREEN_STATE" ] || return 1
    read -r have <"$BAR_SCREEN_STATE" || return 1
    [ "$want" = "$have" ]
}

# Open the bar and confirm it appeared — the daemon may still be coming up, and
# `open`'s exit code lies, so active-windows decides. Screen resolved once.
eww_open_bar() {
    local i screen
    screen="$(eww_screen)"
    for ((i = 0; i < 3; i++)); do
        "$EWW" --config "$CFG" open bar --screen "$screen" 2>/dev/null
        if eww_bar_is_open; then
            printf '%s\n' "$screen" >"$BAR_SCREEN_STATE"
            return 0
        fi
        sleep 0.5
    done
    rm -f "$BAR_SCREEN_STATE"
    return 1
}
