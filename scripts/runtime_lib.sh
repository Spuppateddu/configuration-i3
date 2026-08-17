#!/usr/bin/env bash
# Where the bar's lock / pid / state files live. Sourced, not executed.
#
# Never /tmp — world-writable, so another user can plant a state file or a
# symlink our `>` then truncates. The $HOME fallback survives reboots, so
# anything storing a pid there must re-validate it (restart_kbd.sh).
i3rc_runtime_dir() {
    local d="${XDG_RUNTIME_DIR:-}"
    if [ -z "$d" ] || [ ! -d "$d" ]; then
        d="${XDG_CACHE_HOME:-$HOME/.cache}/i3rc"
        mkdir -p "$d" 2>/dev/null
    fi
    printf '%s\n' "$d"
}

# Set I3RC_SCRIPT to the script pid $1 runs, returning 0 only if that process is
# really a shell running a script. Callers match I3RC_SCRIPT how they like.
#
# The guard behind every `kill` here: `pkill -f <path>` also matches an editor
# holding the script open. Requiring argv[0] to be a shell is what excludes it.
i3rc_script_of_pid() {
    local args
    I3RC_SCRIPT=""
    [ -r "/proc/$1/cmdline" ] || return 1
    mapfile -d '' -t args < "/proc/$1/cmdline" 2>/dev/null || return 1
    [ "${#args[@]}" -gt 0 ] || return 1
    case "${args[0]##*/}" in bash|sh|dash) ;; *) return 1 ;; esac

    # The first word that is neither the shell nor an option, NOT the last one:
    # `float.sh watch` ends on `watch`, and two copies of a daemon stayed alive.
    local a
    for a in "${args[@]:1}"; do
        case $a in -*) continue ;; esac
        I3RC_SCRIPT=$a
        break
    done
    [ -n "$I3RC_SCRIPT" ]
}
