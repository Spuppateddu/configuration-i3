#!/usr/bin/env bash
# Launch the eww bar on the primary output only; other outputs' workspaces show
# as detached cards. Re-runs on every i3 restart, hence the flock and the sweep.
#
# `9>&-` on the daemon: inheriting the lock fd would hold the flock for its whole
# lifetime, and every later run would time out without rebuilding.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Brings REPO, EWW, CFG and (via runtime_lib) i3rc_runtime_dir.
source "$HERE/eww_lib.sh" || exit 1

exec 9>"$(i3rc_runtime_dir)/i3rc-launch-eww.lock"
flock -w 15 9 || exit 0   # another run is already doing this

# The rebuild below costs ~1.5s, so skip it unless the bar is gone or sitting on
# the wrong output — scr.mon follows output changes without a reopen.
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

"$EWW" --config "$CFG" kill 2>/dev/null
sweep_listeners
sleep 0.5

"$EWW" --config "$CFG" daemon 9>&-
sleep 0.5

# Waits out the cold-boot window (an empty --screen fails the open outright) and
# confirms the bar appeared.
eww_open_bar
