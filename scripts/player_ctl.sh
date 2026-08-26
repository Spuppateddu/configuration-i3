#!/usr/bin/env bash
# One-shot transport helper for the eww bar; the player ranking lives in
# scripts/player_lib.sh (_player_rank). Bar *state* comes from player.sh.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/player_lib.sh" || exit 1
source "$HERE/emit_lib.sh"   || exit 1   # pango_escape

case "$1" in
    toggle) pctl play-pause ;;
    next)   pctl next       ;;
    prev)   pctl previous   ;;

    show-title)
        command -v playerctl >/dev/null 2>&1 || exit 0
        # player_state already batches title/artist/album; re-asking would be
        # three more playerctl spawns for data in hand.
        player_state
        [ -z "$PLAYER" ] && exit 0
        [ -z "$TITLE$ARTIST$ALBUM" ] && exit 0
        body=""
        [ -n "$ARTIST" ] && body="$ARTIST"
        [ -n "$ALBUM" ] && body="${body:+$body — }$ALBUM"
        # dunst parses both halves as Pango, and this text is arbitrary — an
        # artist called "Simon & Garfunkel" fails the parse unescaped.
        pango_escape summary "${TITLE:-(no title)}"
        pango_escape body "$body"
        notify-send -a "player" -r 90910 -t 5000 "$summary" "$body"
        ;;
    *)
        echo "usage: ${0##*/} toggle|next|prev|show-title" >&2
        exit 2
        ;;
esac
