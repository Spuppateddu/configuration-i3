#!/usr/bin/env bash
# Recolor the focused-window border for i3 resize mode.
#
# i3 cannot change client.focused at runtime, so this swaps a small include file
# and reloads — which also resets the mode, hence "on" re-entering resize.
#   on -> red border  |  off -> default + leave the mode  |  clear -> at i3 start
set -eu

# Hardcoded: i3's `include` cannot expand an environment variable, so honouring
# XDG_CACHE_HOME would just put the file somewhere i3 never reads.
override="$HOME/.cache/i3/focus-override.conf"
mkdir -p "$(dirname "$override")"

case "${1:-off}" in
    on)
        printf 'client.focused #fb4934 #fb4934 #282828 #fb4934 #fb4934\n' > "$override"
        i3-msg reload >/dev/null
        i3-msg mode resize >/dev/null
        ;;
    off)
        # Reload unconditionally: nothing here runs `mode default`, so this is
        # the only way out of resize mode. Use `clear` when there is no mode.
        : > "$override"
        i3-msg reload >/dev/null
        ;;
    clear)
        # i3-start form: drop an override a crash left behind. Reload only if
        # there was one, or every i3 restart pays a second config parse.
        had_override=false
        [ -s "$override" ] && had_override=true
        : > "$override"     # unconditional: `config`'s include needs it to exist
        if $had_override; then
            i3-msg reload >/dev/null
        fi
        ;;
    *)
        echo "usage: ${0##*/} on|off|clear" >&2
        exit 2
        ;;
esac
