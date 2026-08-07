#!/usr/bin/env bash
# Emits i3 workspaces grouped by output as JSON, on every workspace/output event.
# Shape: {"HDMI-1":[{num,name,label,cmd,focused,visible,urgent},...], "eDP-1":[...]}

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/scripts/emit_lib.sh" || exit 1   # resubscribe_loop

# `cmd` is the button's whole onclick line — eww runs it through `sh -c`, so it
# is escaped twice here: i3str for i3's parser, @sh for the shell.
#
# num == -1 means no numeric prefix, and `workspace number -1` is a silent
# no-op, so those switch by name; `number` otherwise, since it survives renames.
emit() {
    i3-msg -t get_workspaces 2>/dev/null | jq -c '
        def i3str: "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"")) + "\"";
        group_by(.output)
        | map({key: .[0].output,
               value: map({num, name,
                           label: (.name | sub("^[0-9]+: *"; "")),
                           cmd: ("i3-msg " + ((if .num >= 0
                                               then "workspace number \(.num)"
                                               else "workspace " + (.name | i3str)
                                               end) | @sh) + " >/dev/null"),
                           focused, visible, urgent})})
        | from_entries' 2>/dev/null || echo '{}'
}

events() { i3-msg -t subscribe -m '["workspace","output"]'; }

# Reconnects on its own — an i3 restart drops the subscription, and eww never
# respawns a deflisten that exited. See scripts/emit_lib.sh.
resubscribe_loop "" emit events
