#!/usr/bin/env bash
# Lock the screen: best-linux-environment's b-lock (styled i3lock) when installed, else plain i3lock.
# Options go through to i3lock; xss-lock passes --nofork. exec keeps the process named i3lock.
lock="$HOME/.local/bin/b-lock"
[[ -x "$lock" ]] && exec "$lock" "$@"
exec i3lock "$@"
