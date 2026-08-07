#!/usr/bin/env bash
# Rofi bluetooth menu: adapter toggle, connect/disconnect paired devices,
# open blueman-manager. "toggle" argument flips adapter power directly.

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Material Design glyphs kept as ANSI-C escapes so the source stays pure ASCII.
I_ON=$'\U000F00AF'
I_CONN=$'\U000F00B1'
I_OFF=$'\U000F00B2'
I_MGR=$'\U000F0493'

powered() {
    [ "$(bluetoothctl show 2>/dev/null | awk '/Powered:/{print $2; exit}')" = "yes" ]
}

if [ "$1" = "toggle" ]; then
    if powered; then
        bluetoothctl power off >/dev/null
    else
        bluetoothctl power on >/dev/null
    fi
    exit 0
fi

# The whole connected set in one call — `bluetoothctl info` per device costs
# ~100ms of D-Bus each. Needs bluez >= 5.65 for the `devices <filter>` form.
declare -A is_connected
while read -r _ mac _; do
    [ -n "$mac" ] && is_connected["$mac"]=yes
done < <(bluetoothctl devices Connected 2>/dev/null)

# Actions keyed on the exact label, glyph included — pattern-matching meant a
# device named "Manager" ran the manager action instead of connecting.
declare -A action_of
entry() { entries+=${entries:+$'\n'}"$1"; action_of["$1"]=$2; }

entries=""
if powered; then
    entry "$I_OFF Turn off" "power:off"
else
    entry "$I_ON Turn on" "power:on"
fi

while read -r _ mac name; do
    [ -z "$mac" ] && continue
    if [ "${is_connected[$mac]:-no}" = yes ]; then
        entry "$I_CONN $name" "disconnect:$mac"
    else
        entry "$I_ON $name" "connect:$mac"
    fi
done < <(bluetoothctl devices Paired 2>/dev/null)

entry "$I_MGR Manager" manager

lines=$(printf '%s\n' "$entries" | wc -l)
chosen=$(printf '%s\n' "$entries" | rofi -dmenu -i -no-show-icons -p "Bluetooth" \
    -theme "$REPO/rofi/powermenu.rasi" \
    -theme-str "listview {lines: $lines;}")
[ -z "$chosen" ] && exit 0

# Empty for free text: rofi -dmenu accepts anything typed, not just the rows.
action=${action_of["$chosen"]:-}
[ -z "$action" ] && exit 0

case "${action%%:*}" in
    manager)    blueman-manager >/dev/null 2>&1 & ;;
    power)      bluetoothctl power "${action#*:}" >/dev/null ;;
    connect)    bluetoothctl connect "${action#*:}" >/dev/null ;;
    disconnect) bluetoothctl disconnect "${action#*:}" >/dev/null ;;
esac
