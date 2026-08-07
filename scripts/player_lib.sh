#!/usr/bin/env bash
# Shared player-selection logic (sourced by player_ctl.sh and eww/scripts/player.sh).
#
# Priority when picking the "active" player for title + transport buttons:
#   1. mpd if it is Playing.
#   2. any other player that is Playing.
#   3. whichever player was last seen Playing, if it is Paused.
#   4. mpd if it is Paused.
#   5. any other player that is Paused.
#
# Rule 3 stops the bar changing its mind: without it, pausing a video handed the
# transport back to a paused mpd, so the next play resumed the wrong thing.
#
# "Last seen Playing" is kept in a runtime file — MPRIS has no such notion — so
# the one-shot player_ctl.sh and the bar agree on who the buttons belong to.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/runtime_lib.sh" || return 1
PLAYER_ACTIVE_FILE="$(i3rc_runtime_dir)/i3rc-player-active"

# Every field of every player in one `playerctl` call (this runs 3×/second while
# a title scrolls). 0x1f delimits: any printable separator occurs in real titles.
PLAYER_FMT=$'{{playerName}}\x1f{{status}}\x1f{{title}}\x1f{{artist}}\x1f{{album}}'

# Rank a name:status pair by the priority above; non-zero if neither Playing nor
# Paused. Reads $LAST_ACTIVE, which player_state loads before its first call.
_player_rank() {
    case "$1:$2" in
        mpd:Playing) RANK=1 ;;
        *:Playing)   RANK=2 ;;
        *:Paused)
            # Empty check: without it a nameless line would rank as the sticky one.
            if [ -n "$LAST_ACTIVE" ] && [ "$1" = "$LAST_ACTIVE" ]; then RANK=3
            elif [ "$1" = mpd ]; then                                  RANK=4
            else                                                       RANK=5
            fi ;;
        *)           return 1 ;;
    esac
}

# Remember $1 as the player last seen playing. Cached so the 3×/second refresh
# doesn't write a syscall per frame for a value that rarely moves.
_pa_cached=""
_player_remember() {
    [ "$1" = "$_pa_cached" ] && return 0
    _pa_cached=$1
    printf '%s\n' "$1" >"$PLAYER_ACTIVE_FILE" 2>/dev/null
    return 0
}

# Sets PLAYER/STATUS/TITLE/ARTIST/ALBUM to the active player's state. All empty
# when nothing is up.
player_state() {
    local name st ti ar al best=9
    PLAYER="" STATUS="" TITLE="" ARTIST="" ALBUM="" RANK=0

    # Load before ranking, not after: _player_rank consults it per candidate.
    LAST_ACTIVE=""
    [ -r "$PLAYER_ACTIVE_FILE" ] && read -r LAST_ACTIVE <"$PLAYER_ACTIVE_FILE"

    while IFS=$'\x1f' read -r name st ti ar al; do
        [ -n "$name" ] || continue
        _player_rank "$name" "$st" || continue
        [ "$RANK" -lt "$best" ] || continue
        best=$RANK
        PLAYER=$name STATUS=$st TITLE=$ti ARTIST=$ar ALBUM=$al
    done < <(playerctl -a metadata --format "$PLAYER_FMT" 2>/dev/null)

    if [ -n "$PLAYER" ]; then
        # Only a *playing* player updates the memory, or the paused winner of
        # rule 3 would re-record itself and never be displaced.
        [ "$STATUS" = "Playing" ] && _player_remember "$PLAYER"
        return 0
    fi

    # `playerctl -a metadata` skips players exposing none, which would drop them
    # from the bar entirely. Slower per-player probe as a fallback; no metadata.
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        st=$(playerctl -p "$name" status 2>/dev/null)
        _player_rank "$name" "$st" || continue
        [ "$RANK" -lt "$best" ] || continue
        best=$RANK
        PLAYER=$name STATUS=$st
    done < <(playerctl -l 2>/dev/null)
    return 0
}

# Run playerctl against an already-resolved name ("" = anything but mpd). Use
# this over pctl for multiple commands — pctl re-runs the selection scan each time.
pctl_to() {
    local p=$1
    shift
    if [ -n "$p" ]; then
        playerctl -p "$p" "$@"
    else
        playerctl --ignore-player=mpd "$@" 2>/dev/null
    fi
}

# One-shot convenience wrapper: resolve the active player, then act on it.
pctl() {
    player_state
    pctl_to "$PLAYER" "$@"
}
