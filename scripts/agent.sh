#!/usr/bin/env bash
# Open the coding agent this machine uses, in its own folder, as a new window of
# a tmux session named after it — reusing the terminal already showing it.
# Both from config.local: `set $agent claude`, `set $agent_desk ~/agent-desk`.

set -u

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/agent_lib.sh" || exit 1

fail() {
    notify-send -i dialog-error "Agent" "$1"
    exit 1
}

# Read the values here, not through i3: `include ~/.i3rc/*.local` is the config's
# last line, and i3 substitutes as it parses — too late for the bindsym above.
cmd=$(i3rc_local_set "$REPO" agent)

[ -n "$cmd" ] || fail 'No agent configured — put `set $agent claude` in ~/.i3rc/config.local'

# Split on spaces so `claude --continue` reaches the agent as arguments. A shell
# would be needed for pipes or &&; wrap those in a script and name that instead.
read -r -a argv <<<"$cmd"
command -v "${argv[0]}" >/dev/null 2>&1 || fail "Agent not installed: ${argv[0]}"

# Its own folder, not $HOME: trusting the whole home hands it every file you own.
# setup.sh makes it; made here too, so the key works on a machine that skipped it.
DESK=$(i3rc_agent_desk "$REPO") ||
    fail 'Agent folder must be an absolute path — fix `set $agent_desk` in ~/.i3rc/config.local'

mkdir -p -- "$DESK" || fail "Cannot create the agent folder: $DESK"

command -v tmux >/dev/null 2>&1 || fail "tmux not installed"

# One tmux session per agent, named after it: every $mod+c is a new window there,
# so closing the terminal loses nothing and `tmux attach -t claude` gets it back.
SESSION=${argv[0]##*/}
CLASS=ble-agent

if tmux has-session -t "=$SESSION" 2>/dev/null; then
    tmux new-window -t "=$SESSION:" -n "$SESSION" -c "$DESK" "${argv[@]}" ||
        fail "Cannot open a window in tmux session $SESSION"
else
    tmux new-session -d -s "$SESSION" -n "$SESSION" -c "$DESK" "${argv[@]}" ||
        fail "Cannot start tmux session $SESSION"
fi

# Terminal already on screen: the new window shows up in it, just bring it forward.
i3-msg -q "[instance=\"$CLASS\"] focus" 2>/dev/null && exit 0

# --working-directory, not i3's cwd: i3 passes on whatever directory it was
# started from — $HOME on a login, but not after a restart from a terminal.
exec alacritty --class "$CLASS" --working-directory "$DESK" -e tmux attach-session -t "=$SESSION"
