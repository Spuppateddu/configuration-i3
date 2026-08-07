#!/usr/bin/env bash
# Shared helpers for the bar's deflisten emitters (eww/scripts/*.sh).
# Sourced, not executed.

# Escape $2 as a JSON string body into the variable named by $1. `printf -v` to
# avoid a fork per field; the local is `_`-prefixed so it can't shadow $1.
json_escape() {
    local _je_s=$2
    _je_s=${_je_s//\\/\\\\}
    _je_s=${_je_s//\"/\\\"}
    _je_s=${_je_s//$'\n'/\\n}
    _je_s=${_je_s//$'\r'/\\r}
    _je_s=${_je_s//$'\t'/\\t}
    _je_s=${_je_s//[[:cntrl:]]/}   # anything else C0 has no place in a track title
    printf -v "$1" '%s' "$_je_s"
}

# Escape $2 as Pango markup into $1 — dunst parses notifications with
# `markup = full`, and a folder named "Simon & Garfunkel" fails the parse.
#
# '&' first, or the others' entities get re-escaped. `\&` because bash 5.2's
# patsub_replacement makes a bare `&` in a replacement mean "what matched".
pango_escape() {
    local _pe_s=$2
    _pe_s=${_pe_s//&/\&amp;}
    _pe_s=${_pe_s//</\&lt;}
    _pe_s=${_pe_s//>/\&gt;}
    printf -v "$1" '%s' "$_pe_s"
}

# Emit once, then on every event, re-subscribing whenever the stream ends — eww
# never respawns a dead deflisten, so without this the widget freezes for good.
#
#   $1  pre-(re)connect hook, or "" — the inner loop is a subshell, so any state
#       it built is lost and eww's held value must be re-sent unconditionally.
#   $2  emitter. Gets the raw event burst as $1, or nothing on a (re)connect.
#   $3  event source. A function so callers can filter inside it (volume.sh).
#
# Bursts are coalesced over 10ms: one workspace switch fires several events that
# all re-read to the same state. A truncated line costs one extra emit at worst,
# so an emitter classifying a burst must fail toward re-reading.
resubscribe_loop() {
    local pre=$1 emit=$2 events=$3 line burst
    while true; do
        [ -n "$pre" ] && "$pre"
        "$emit"
        "$events" 2>/dev/null | while read -r line; do
            burst=$line
            # drain the rest of the burst, keeping it for the emitter
            while read -r -t 0.01 line; do burst="$burst"$'\n'"$line"; done
            "$emit" "$burst"
        done
        sleep 1
    done
}
