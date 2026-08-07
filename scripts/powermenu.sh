#!/usr/bin/env bash
# Simple rofi-based power menu.

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

chosen=$(printf '\U000F033E Lock\n\U000F04B2 Suspend\n\U000F0343 Logout\n\U000F0709 Reboot\n\U000F0425 Shutdown' | \
    rofi -dmenu -i -no-show-icons -p "Power" -theme "$REPO/rofi/powermenu.rasi")

case "$chosen" in
    *Lock)      i3lock ;;
    *Suspend)   systemctl suspend ;;
    *Logout)    i3-msg exit ;;
    *Reboot)    systemctl reboot ;;
    *Shutdown)  systemctl poweroff ;;
esac
