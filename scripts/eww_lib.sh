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

# The bars that are up, "<id> <screen> <mon>" per line. launch_eww.sh compares
# it against what the outputs ask for now, to skip a rebuild that changes nothing.
BAR_SCREEN_STATE="$(i3rc_runtime_dir)/i3rc-eww-screen"

# Which outputs get a bar: `all` — one per active monitor — or `main`, the
# primary alone with the other monitors' workspaces as detached cards on it.
# Written by best-linux-environment (settings.local, BLE_I3_BAR); `all` without it.
BAR_MODE_CONF="$CFG/bar.local.conf"

# Read as data, never sourced: the file comes from another repo, and a typo in
# it must cost one line rather than every script that asks the question.
bar_mode() {
    local v=""
    [ -r "$BAR_MODE_CONF" ] && v=$(sed -n \
        's/^[[:space:]]*BAR_SCREENS[[:space:]]*=[[:space:]]*\([A-Za-z]*\).*/\1/p' \
        "$BAR_MODE_CONF" 2>/dev/null | tail -n1)
    case "$v" in main) printf 'main\n' ;; *) printf 'all\n' ;; esac
}

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

# Every output that gets a bar, "<name> <width_px>" per line: all the active
# ones, primary first, or the primary alone in `main` mode. Empty during the
# cold-boot window, exactly like primary_output.
bar_outputs() {
    [ "$(bar_mode)" = main ] && { primary_output; return; }
    i3-msg -t get_outputs 2>/dev/null | jq -r '
        [.[] | select(.active)] | sort_by(.primary | not)
        | .[] | "\(.name) \(.rect.width)"' 2>/dev/null
}

# The bars that should be open, "<id> <screen> <mon>" per line. One window id per
# output: `eww close` takes the id, and two bars may never share one.
bar_targets() {
    local name _w
    while read -r name _w; do
        [ -n "$name" ] || continue
        printf 'bar-%s %s %s\n' "$name" "$name" "$name"
    done < <(bar_outputs)
}

# Where every active output sits, "<name> <x> <y> <w> <h>" per line. A bar is
# placed at fixed pixels when it opens, so moving, rotating or resizing a monitor
# (ARandR) leaves it behind even when the output names stay the same — i3 then
# docks it on whichever output now holds those pixels: two bars on one monitor,
# none on the other. Saved next to the targets, so any layout change rebuilds.
output_layout() {
    i3-msg -t get_outputs 2>/dev/null | jq -r '
        [.[] | select(.active)] | sort_by(.name)
        | .[] | "\(.name) \(.rect.x) \(.rect.y) \(.rect.width) \(.rect.height)"' 2>/dev/null
}

# What the saved state must match for the bars to be current: the targets, then
# the layout. Empty during the cold-boot window, exactly like bar_targets.
bar_state() {
    local targets
    targets="$(bar_targets)"
    [ -n "$targets" ] || return 0
    printf '%s\n' "$targets"
    output_layout
}

# Like bar_targets, but waits out the cold-boot window — an empty --screen fails
# the open outright. The fallback is screen 0 (always valid) with no output name,
# which puts every workspace in the detached cards until an event corrects it.
bar_targets_wait() {
    local out i
    for ((i = 0; i < 30; i++)); do          # ~6s ceiling; usually resolves at once
        out=$(bar_targets)
        [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
        sleep 0.2
    done
    printf 'bar 0 \n'
    return 0
}

# The ids of the bar windows open right now, one per line ("<id>: <name>").
eww_bar_ids() {
    "$EWW" --config "$CFG" active-windows 2>/dev/null | sed -n 's/^\(bar[^:]*\):.*/\1/p'
}

# True when a bar window is open on any output.
eww_bar_is_open() {
    [ -n "$(eww_bar_ids)" ]
}

# True when the bars up now are exactly the ones the outputs ask for — a restart
# has nothing to rebuild. Non-blocking: no output yet means take the startup path.
eww_bar_is_current() {
    local want have
    eww_bar_is_open || return 1
    want="$(bar_state)"
    [ -n "$want" ] || return 1
    # Tested before opening: redirections apply left to right, so `<missing
    # 2>/dev/null` still prints the failure before stderr is silenced.
    [ -r "$BAR_SCREEN_STATE" ] || return 1
    have="$(cat "$BAR_SCREEN_STATE")" || return 1
    [ "$want" = "$have" ] || return 1
    # The state file says what was opened; this says it is still there.
    [ "$(eww_bar_ids | sort)" = "$(bar_targets | awk '{print $1}' | sort)" ]
}

# Open one bar per target output and confirm they appeared — the daemon may
# still be coming up, and `open`'s exit code lies, so active-windows decides.
eww_open_bar() {
    local i id screen mon others targets want
    # `others`: the other outputs' workspaces ride on this bar only when they
    # have no bar of their own — in `main` mode, or before an output resolves.
    [ "$(bar_mode)" = main ] && others=true || others=false

    targets="$(bar_targets_wait)"
    want="$(printf '%s\n' "$targets" | awk '{print $1}' | sort)"

    for ((i = 0; i < 3; i++)); do
        while read -r id screen mon; do
            [ -n "$id" ] || continue
            eww_bar_ids | grep -qx -- "$id" && continue
            "$EWW" --config "$CFG" open bar --id "$id" --screen "$screen" \
                   --arg "mon=$mon" \
                   --arg "others=$([ -z "$mon" ] && printf true || printf '%s' "$others")" \
                   2>/dev/null
        done <<<"$targets"
        if [ "$(eww_bar_ids | sort)" = "$want" ]; then
            { printf '%s\n' "$targets"; output_layout; } >"$BAR_SCREEN_STATE"
            return 0
        fi
        sleep 0.5
    done
    rm -f "$BAR_SCREEN_STATE"
    return 1
}

# Close every bar window, whatever output it was opened on.
eww_close_bars() {
    local id
    while read -r id; do
        [ -n "$id" ] && "$EWW" --config "$CFG" close "$id" 2>/dev/null
    done < <(eww_bar_ids)
    rm -f "$BAR_SCREEN_STATE"
}
