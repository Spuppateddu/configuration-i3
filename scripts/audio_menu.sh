#!/usr/bin/env bash
# Rofi audio menu: pick the output and the input. One row per port, so Speakers
# and Headphones on one card are two rows; apps already playing move along.

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

I_SPK=$'\U000F04C3'
I_HP=$'\U000F02CB'
I_HDMI=$'\U000F0379'
I_MIC=$'\U000F036C'
I_ON=$'\U000F012C'
I_MGR=$'\U000F0493'

def_sink=$(pactl get-default-sink 2>/dev/null)
def_src=$(pactl get-default-source 2>/dev/null)

# One TSV row per port: kind, device, port, label, type, availability, active.
# Monitor sources are the speakers' echo, not a microphone, so they are skipped.
rows() {
    pactl -f json list "$1" 2>/dev/null | jq -r --arg kind "$2" '
        [.[] | select(.monitor_source == "" or .monitor_source == null or $kind == "out")] as $devs
        | $devs[] as $d
        | ($d.ports | if length == 0 then [{name: "", description: $d.description, type: "", availability: ""}] else . end)[] as $p
        | [$kind, $d.name, $p.name,
           (if ($devs | length) > 1 and ($d.ports | length) > 0 then "\($p.description) · \($d.description)" else $p.description end),
           ($p.type // ""), ($p.availability // ""), ($d.active_port // "")] | @tsv'
}

icon_for() {
    case "$1:$2" in
        in:*)                 printf '%s' "$I_MIC" ;;
        *:Headphones|*:Headset) printf '%s' "$I_HP" ;;
        *:HDMI|*:DisplayPort) printf '%s' "$I_HDMI" ;;
        *)                    printf '%s' "$I_SPK" ;;
    esac
}

# Actions keyed on the exact label, like bluetooth_menu.sh: free text typed
# into rofi matches no key and does nothing.
declare -A action_of
entries=""
active=""
n=0
entry() {
    entries+=${entries:+$'\n'}"$1"; action_of["$1"]=$2
    [ "$3" = yes ] && active+=${active:+,}$n
    n=$((n + 1))
}

add_kind() {
    local kind=$1 list=$2 def=$3 dev port label type avail cur on
    entry "$5  $4" "" no
    while IFS=$'\t' read -r kind dev port label type avail cur; do
        [ -z "$dev" ] && continue
        on=no
        [ "$dev" = "$def" ] && { [ -z "$port" ] || [ "$port" = "$cur" ]; } && on=yes
        [ "$avail" = "not available" ] && label+="  (not plugged in)"
        label="    $(icon_for "$kind" "$type")  $label"
        [ "$on" = yes ] && label+="  $I_ON"
        entry "$label" "$kind:$dev:$port" "$on"
    done < <(rows "$list" "$kind")
}

add_kind out sinks "$def_sink" Output "$I_SPK"
add_kind in sources "$def_src" Input "$I_MIC"
entry "$I_MGR  Advanced…" manager no

lines=$(printf '%s\n' "$entries" | wc -l)
chosen=$(printf '%s\n' "$entries" | rofi -dmenu -i -no-show-icons -p "Audio" \
    -theme "$REPO/rofi/powermenu.rasi" -a "$active" \
    -theme-str "window {width: 440px;} listview {lines: $lines;}")
[ -z "$chosen" ] && exit 0

action=${action_of["$chosen"]:-}
[ -z "$action" ] && exit 0
[ "$action" = manager ] && { pavucontrol >/dev/null 2>&1 & exit 0; }

IFS=: read -r kind dev port <<<"$action"
if [ "$kind" = out ]; then
    [ -n "$port" ] && pactl set-sink-port "$dev" "$port"
    pactl set-default-sink "$dev"
    pactl list short sink-inputs | cut -f1 | xargs -r -I{} pactl move-sink-input {} "$dev"
else
    [ -n "$port" ] && pactl set-source-port "$dev" "$port"
    pactl set-default-source "$dev"
    pactl list short source-outputs | cut -f1 | xargs -r -I{} pactl move-source-output {} "$dev"
fi
