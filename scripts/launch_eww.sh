#!/usr/bin/env bash
# Launch the eww bar: one per monitor, or on the primary alone with the other
# outputs' workspaces as detached cards — scripts/eww_lib.sh's bar_mode decides.
# Re-runs on every i3 restart, hence the flock and the sweep.
#
# `9>&-` on the daemon: inheriting the lock fd would hold the flock for its whole
# lifetime, and every later run would time out without rebuilding.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Brings REPO, EWW, CFG and (via runtime_lib) i3rc_runtime_dir.
source "$HERE/eww_lib.sh" || exit 1

exec 9>"$(i3rc_runtime_dir)/i3rc-launch-eww.lock"
flock -w 15 9 || exit 0   # another run is already doing this

# The rebuild below costs ~1.5s, so skip it unless a bar is gone or sitting on
# an output that no longer exists.
eww_bar_is_current && exit 0

# Sweep listeners orphaned by a daemon that died without reaping them. The match
# must be exact — `pkill -f` would also hit anything merely naming that path.
sweep_listeners() {
    local pid
    for pid in $(pgrep -f "$CFG/scripts/" 2>/dev/null); do
        [ "$pid" = "$$" ] && continue
        i3rc_script_of_pid "$pid" || continue
        case "$I3RC_SCRIPT" in "$CFG"/scripts/*.sh) kill "$pid" 2>/dev/null ;; esac
    done
}

# `eww kill` reaches only the daemon that owns the socket; one that lost it to a
# second daemon keeps drawing its bar, so kill every daemon of this config by pid.
# The config path is compared resolved: ~/.i3rc/eww and the repo's own path are
# the same config (and the same socket), so a daemon started through either counts.
kill_daemons() {
    local pid args cfg
    cfg="$(readlink -f -- "$CFG")"
    "$EWW" --config "$CFG" kill 2>/dev/null
    for pid in $(pgrep -x eww 2>/dev/null); do
        mapfile -t args < <(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | head -n3)
        [ "${args[0]}" = "$EWW" ] && [ "${args[1]}" = --config ] \
            && [ "$(readlink -f -- "${args[2]}")" = "$cfg" ] && kill "$pid" 2>/dev/null
    done
}

# No state while rebuilding: screen.sh starting mid-way must not read the old one.
rm -f "$BAR_SCREEN_STATE"
kill_daemons
sweep_listeners
sleep 0.5

# `open` with no daemon answering starts a second one, hence the ping wait.
"$EWW" --config "$CFG" daemon 9>&-
for ((i = 0; i < 50; i++)); do                 # ~5s ceiling
    "$EWW" --config "$CFG" ping >/dev/null 2>&1 && break
    sleep 0.1
done

# Waits out the cold-boot window (an empty --screen fails the open outright) and
# confirms every bar appeared.
eww_open_bar
