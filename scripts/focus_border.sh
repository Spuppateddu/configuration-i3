#!/usr/bin/env bash
# The focused window wears a thicker border than the rest. i3 has no setting for
# it — only per-focus *colours* — so `watch` redraws it on every focus change.
#
# Width only, never style: a window keeps its own `normal` or `pixel`, so this
# never puts back a title bar the desktop is not wearing.
#   watch -> daemon, from exec_always   |  clear -> put every window back

set -u

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/runtime_lib.sh" || exit 1

PIDFILE="$(i3rc_runtime_dir)/i3rc-focus-border.pid"

# The catch-all width config gives every window, and what the focused one grows
# to. Only these two widths are ever touched, so a per-app `pixel 1` and
# window_mode.py's preview box (its own window) stay exactly as they are.
BASE_PX=${I3RC_BASE_BORDER_PX:-3}
FOCUS_PX=${I3RC_FOCUS_BORDER_PX:-4}

JQ_DESC='def desc: recurse(.nodes[]?, .floating_nodes[]?);'

# One pass over the tree: thicken the focused window, thin every other one that
# is still thick. Stateless, so a missed event or an i3 restart self-heals.
sync() {
    local only_focused=${1:-0} cmd
    cmd=$(i3-msg -t get_tree 2>/dev/null | jq -r \
        --argjson base "$BASE_PX" --argjson focus "$FOCUS_PX" \
        --argjson keep "$only_focused" "$JQ_DESC"'
        [ desc | select(.window != null) | select(.border != "none")
        | if .focused then
              select($keep == 0 and .current_border_width == $base)
              | "[con_id=\(.id)] border \(.border) \($focus)"
          else
              select(.current_border_width == $focus)
              | "[con_id=\(.id)] border \(.border) \($base)"
          end ] | join("; ")' 2>/dev/null)
    [ -n "${cmd:-}" ] || return 0
    i3-msg "$cmd" >/dev/null 2>&1 || true
}

# Same pidfile dance as float.sh: exec_always re-runs us on every i3 restart,
# and without this a hand-started copy would keep subscribing too.
is_self() {
    local me="${BASH_SOURCE[0]##*/}"
    i3rc_script_of_pid "$1" || return 1
    [ "${I3RC_SCRIPT##*/}" = "$me" ]
}

release_pidfile() {
    local cur
    [ -r "$PIDFILE" ] || return 0
    read -r cur <"$PIDFILE" || return 0
    [ "$cur" = "$$" ] && rm -f "$PIDFILE"
    return 0
}

cmd_watch() {
    local old ev sub_pid
    if [ -r "$PIDFILE" ]; then
        read -r old <"$PIDFILE" || old=""
        case $old in
            ''|*[!0-9]*|"$$") ;;
            *) is_self "$old" && kill "$old" 2>/dev/null ;;
        esac
    fi
    printf '%s\n' "$$" >"$PIDFILE"

    # Process substitution, not a pipeline: the read has to stay in *this* shell,
    # or the trap below only fires once the stream ends — never.
    exec 3< <(i3-msg -t subscribe -m '[ "window" ]' 2>/dev/null)
    sub_pid=$!
    trap 'kill "$sub_pid" 2>/dev/null; release_pidfile' EXIT
    trap 'exit 0' TERM INT

    sync
    # The string test first: the title changes a terminal emits on every command
    # would each cost a tree read otherwise. A close needs no pass of its own —
    # the focus that follows it does the work.
    while read -r ev <&3; do
        case $ev in
            *'"change":"focus"'*|*'"change":"new"'*|*'"change":"floating"'*) sync ;;
        esac
    done
}

case "${1:-}" in
    watch) cmd_watch ;;
    clear) sync 1 ;;
    *)     printf 'usage: %s watch | clear\n' "${0##*/}" >&2; exit 2 ;;
esac
