#!/usr/bin/env bash
# Shared network helpers (sourced by eww/scripts/network.sh).
#
# Writes through named variables, never echo — this runs twice a second, and a
# command substitution is a fork. Locals are `_`-prefixed so they can't shadow $1.

# Sets IFACE / IFACE_KIND to the best active interface, both empty when there is
# none. Wireless wins over wired; the first wired one is the fallback.
#
# The `device` link separates a real NIC from a virtual one — without it,
# `docker0` sorts before `enp*` and wins the wired fallback the moment it is up.
pick_iface() {
    local wired="" name path state
    IFACE="" IFACE_KIND=""
    for path in /sys/class/net/*; do
        name=${path##*/}
        [ "$name" = "lo" ] && continue
        [ -e "$path/device" ] || continue
        read -r state 2>/dev/null <"$path/operstate" || continue
        [ "$state" = "up" ] || continue
        if [ -d "$path/wireless" ]; then
            IFACE=$name IFACE_KIND=wifi
            return
        fi
        [ -z "$wired" ] && wired="$name"
    done
    [ -n "$wired" ] && IFACE=$wired IFACE_KIND=eth
    return 0
}

# Sets $1 to the SSID of wireless interface $2, else to the interface name.
# Takes everything after "SSID: ", so an SSID containing ": " survives.
wifi_label() {
    local _wl_iface=$2 _wl_line _wl_label=""
    while IFS= read -r _wl_line; do
        case "$_wl_line" in
            *SSID:*) _wl_label=${_wl_line#*SSID: }; break ;;
        esac
    done < <(iw dev "$_wl_iface" link 2>/dev/null)
    printf -v "$1" '%s' "${_wl_label:-$_wl_iface}"
}
