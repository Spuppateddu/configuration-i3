#!/usr/bin/env bash
# Per-machine agent settings, read out of the git-ignored *.local files.
# Sourced, not executed — by scripts/agent.sh ($mod+c) and by setup.sh.

# The value of one `set $<name> <value>` line, last match winning, the way i3
# itself resolves a variable set twice. i3 keeps the quotes, so drop a pair.
i3rc_local_set() {
    local v
    # `|| true`: with no *.local at all the cat fails, and setup.sh sources this
    # under `set -e -o pipefail`, where an unset variable is not an error.
    v=$(cat -- "$1"/*.local 2>/dev/null |
        sed -n "s/^[[:space:]]*set[[:space:]]\\+\\\$$2[[:space:]]\\+//p" |
        tail -n 1) || true
    v=${v%"${v##*[![:space:]]}"}
    [ "${#v}" -ge 2 ] && [ "${v:0:1}" = '"' ] && [ "${v: -1}" = '"' ] && v=${v:1:-1}
    printf '%s\n' "$v"
}

# Where $mod+c starts the agent: `set $agent_desk <path>`, else ~/agent-desk. No
# shell expands it, so ~ is ours; returns 1 on a relative path (i3's cwd varies).
i3rc_agent_desk() {
    local d
    d=$(i3rc_local_set "$1" agent_desk)
    d=${d:-$HOME/agent-desk}
    case $d in
        '~'|'$HOME')        d=$HOME ;;
        '~/'*)              d=$HOME/${d#\~/} ;;
        '$HOME/'*)          d=$HOME/${d#\$HOME/} ;;
    esac
    printf '%s\n' "$d"
    [ "${d#/}" != "$d" ]
}
