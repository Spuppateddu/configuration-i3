#!/usr/bin/env bash
# Keeps mpd's queue holding every song of the folder play_folder.sh queued (the
# whole library by default), in shuffled order. Run by mpd-queue-sync.service.

QUEUE_FOLDER="$HOME/.local/share/mpd/queue_folder"

# What the folder has and the queue lacks; adding them never stops the playing song.
# LC_ALL=C: comm needs the same byte order as sort, or names with accents repeat.
missing_songs() {
    local target
    target=$(cat "$QUEUE_FOLDER" 2>/dev/null)
    LC_ALL=C comm -23 \
        <(mpc listall "${target:-/}" 2>/dev/null | LC_ALL=C sort -u) \
        <(mpc playlist -f %file% | LC_ALL=C sort -u)
}

# Each new song goes to a random spot after the playing one, not always to the end.
add_at_random_spots() {
    local file len cur
    while IFS= read -r file; do
        mpc -q add "$file" || continue
        len=$(mpc status '%length%')
        cur=$(mpc status '%songpos%')
        cur=${cur:-0}
        (( len - cur > 1 )) && mpc -q move "$len" $(( cur + 1 + RANDOM % (len - cur) ))
    done
}

# auto_update only watches while mpd runs, and the socket starts it on demand:
# songs copied in while it was off need this rescan to be seen at all.
mpc -q update --wait
missing_songs | mpc -q add
# mpd starts once per boot, so this is a fresh order every boot; the playing song stays.
mpc -q shuffle
mpc -q random on

# A new song lands in the database first, then here; mpd itself drops deleted ones.
mpc idleloop database | while read -r _; do
    missing_songs | add_at_random_spots
done
