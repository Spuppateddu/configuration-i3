#!/usr/bin/env bash
# Keyboard tuning: fast repeat + Caps->Ctrl, applied now and re-applied whenever
# an input device is attached (docking, USB keyboard, Bluetooth pairing).
#
# Re-run on every i3 restart, so the previous instance must be killed first or
# they stack on the udev socket. Found via a pidfile, not `pgrep -f`, which
# would also match an editor holding this file open.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/runtime_lib.sh" || exit 1

PIDFILE="$(i3rc_runtime_dir)/i3rc-restart-kbd.pid"

apply() {
    xset r rate 200 50
    setxkbmap -option ctrl:nocaps
}

# The pid in the file is a claim, not proof — the runtime dir can outlive a
# reboot. Basename compare: i3 invokes by absolute path, a hand-run may not.
is_self() {
    local me="${BASH_SOURCE[0]##*/}"
    i3rc_script_of_pid "$1" || return 1
    [ "${I3RC_SCRIPT##*/}" = "$me" ]
}

if [ -r "$PIDFILE" ]; then
    read -r old <"$PIDFILE" || old=""
    case "$old" in
        ''|*[!0-9]*)          ;;                       # empty or junk
        "$$")                 ;;                       # somehow ourselves
        *) is_self "$old" && kill "$old" 2>/dev/null ;;
    esac
fi
# Orphans from the pre-pidfile inline version. -x pins the match to this exact
# command line, so nothing else can be caught by it.
pkill -xf "udevadm monitor --udev --subsystem-match=input" 2>/dev/null

apply

command -v udevadm >/dev/null 2>&1 || exit 0

printf '%s\n' "$$" >"$PIDFILE"

# Process substitution, not a pipeline: keeps the read loop in this shell so the
# trap owns udevadm and can reap it.
open_monitor() {
    exec 3<&-
    exec 3< <(udevadm monitor --udev --subsystem-match=input)
    udev_pid=$!
}

open_monitor

# Drop the pidfile only while it still names *us* — unconditionally, a slow
# SIGTERM cleanup would delete our successor's claim and let two instances stack.
release_pidfile() {
    local cur
    [ -r "$PIDFILE" ] || return 0
    read -r cur <"$PIDFILE" || return 0
    [ "$cur" = "$$" ] && rm -f "$PIDFILE"
    return 0
}
cleanup() { kill "$udev_pid" 2>/dev/null; release_pidfile; }
trap cleanup EXIT
# TERM/INT must `exit` themselves: a trap that just returns resumes the loop
# below, so the process survives the signal and instances stack anyway.
trap 'cleanup; exit 0' TERM INT

# Lines look like `UDEV [1234.5] add /devices/... (input)`. Resubscribes because
# `udevadm monitor` ends on a udev restart, which would silently kill the tuning.
while true; do
    while read -r line <&3; do
        case "$line" in *" add "*) apply ;; esac
    done
    sleep 1
    open_monitor
    apply
done
