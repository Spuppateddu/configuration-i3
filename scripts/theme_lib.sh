#!/usr/bin/env bash
# Shared Alacritty-config helpers (sourced by theme.sh and setup.sh).
#
# The theme file only reaches the terminal if Alacritty's own config imports it,
# and that config isn't ours to edit — so both callers ask the same two questions.

ALACRITTY_THEME_FILE="$HOME/.cache/alacritty-theme.toml"

# Echo the path of Alacritty's config; non-zero and silent when there is none.
alacritty_config() {
    local c
    for c in "${XDG_CONFIG_HOME:-$HOME/.config}/alacritty/alacritty.toml" \
             "$HOME/.config/alacritty/alacritty.toml" \
             "$HOME/.alacritty.toml"; do
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

# True when $1 (an Alacritty config path) imports the generated theme file.
alacritty_imports_theme() {
    grep -q 'alacritty-theme\.toml' "$1" 2>/dev/null
}
