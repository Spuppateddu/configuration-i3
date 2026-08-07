#!/usr/bin/env bash
# Emits network state as JSON for the eww bar (deflisten).
# `kind` (wifi/eth/off) is the only field the bar draws; `label` carries the
# SSID for anything that wants it. The whole tick is builtins — no forks.

INTERVAL=2

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/scripts/net_lib.sh"  || exit 1   # pick_iface, wifi_label
source "$REPO/scripts/emit_lib.sh" || exit 1   # json_escape

# `iw` is the only fork on this path and the SSID barely changes — cache it for
# SSID_TTL ticks (~43k spawns/day down to under 3k).
SSID_TTL=15
ssid_age=0; ssid_iface=""; ssid_label=""

while :; do
    pick_iface                      # sets IFACE / IFACE_KIND

    if [ -z "$IFACE" ]; then
        printf '{"kind":"off","label":"offline"}\n'
        # Drop the cached SSID: coming back up often means a new network.
        ssid_iface=""; ssid_age=0
        sleep "$INTERVAL"
        continue
    fi

    if [ "$IFACE_KIND" = "wifi" ]; then
        if [ "$IFACE" != "$ssid_iface" ] || [ "$ssid_age" -le 0 ]; then
            wifi_label ssid_label "$IFACE"
            ssid_iface=$IFACE; ssid_age=$SSID_TTL
        fi
        ssid_age=$(( ssid_age - 1 ))
        label=$ssid_label
    else
        label=$IFACE
        ssid_iface=""; ssid_age=0
    fi

    # Only the label needs escaping; `kind` is one of our own three literals.
    json_escape jlabel "$label"
    printf '{"kind":"%s","label":"%s"}\n' "$IFACE_KIND" "$jlabel"

    sleep "$INTERVAL"
done
