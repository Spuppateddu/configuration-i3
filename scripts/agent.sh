#!/usr/bin/env bash
# Open a terminal in ~/agent-desk running the coding agent this machine uses.
#
# Which agent is per-machine, so it is not in the shared config. Name it with
# one line of plain i3 syntax in ~/.i3rc/config.local:
#
#   set $agent claude
#
# Any command works — `codex`, `opencode`, `claude --continue`. Nothing in the
# shared config reads that variable, so i3 parses the line and ignores it.

set -u

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Its own folder, not $HOME: an agent asks you to trust the directory it starts
# in, and trusting your whole home hands it every file you own. setup.sh makes
# it; created here too, so the key still works on a machine that skipped setup.
DESK="$HOME/agent-desk"

fail() {
    notify-send -i dialog-error "Agent" "$1"
    exit 1
}

# Read the value here instead of letting i3 substitute $agent into the bindsym:
# `include ~/.i3rc/*.local` is the last line of the config, and i3 substitutes
# as it parses, so a `set` in config.local lands after every binding above it.
# Last match wins, which is how i3 itself resolves a variable set twice.
cmd=$(cat -- "$REPO"/*.local 2>/dev/null |
    sed -n 's/^[[:space:]]*set[[:space:]]\+\$agent[[:space:]]\+//p' |
    tail -n 1)

# i3 accepts the value quoted or bare, and keeps the quotes as part of it.
cmd="${cmd%"${cmd##*[![:space:]]}"}"
[ "${#cmd}" -ge 2 ] && [ "${cmd:0:1}" = '"' ] && [ "${cmd: -1}" = '"' ] && cmd="${cmd:1:-1}"

[ -n "$cmd" ] || fail 'No agent configured — put `set $agent claude` in ~/.i3rc/config.local'

# Split on spaces so `claude --continue` reaches the agent as arguments. A shell
# would be needed for pipes or &&; wrap those in a script and name that instead.
read -r -a argv <<<"$cmd"
command -v "${argv[0]}" >/dev/null 2>&1 || fail "Agent not installed: ${argv[0]}"

mkdir -p -- "$DESK" || fail "Cannot create the agent folder: $DESK"

# --working-directory, not i3's cwd: i3 hands a spawned process whatever
# directory it was started from, which is $HOME on a login but not after a
# restart from a terminal sitting somewhere else.
exec alacritty --working-directory "$DESK" -e "${argv[@]}"
