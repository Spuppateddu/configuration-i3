#!/usr/bin/env bash
# Keeps mpd's queue holding every song of the folder play_folder.sh queued (the
# whole library by default). Run by mpd-queue-sync.service, alongside mpd.

QUEUE_FOLDER="$HOME/.local/share/mpd/queue_folder"

# Adds what the folder has and the queue lacks, so the playing song never stops.
# LC_ALL=C: comm needs the same byte order as sort, or names with accents repeat.
sync_queue() {
    local target
    target=$(cat "$QUEUE_FOLDER" 2>/dev/null)
    LC_ALL=C comm -23 \
        <(mpc listall "${target:-/}" 2>/dev/null | LC_ALL=C sort -u) \
        <(mpc playlist -f %file% | LC_ALL=C sort -u) | mpc -q add
}

# auto_update only watches while mpd runs, and the socket starts it on demand:
# songs copied in while it was off need this rescan to be seen at all.
mpc -q update --wait
sync_queue

# A new song lands in the database first, then here; mpd itself drops deleted ones.
mpc idleloop database | while read -r _; do
    sync_queue
done
