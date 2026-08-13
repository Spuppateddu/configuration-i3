#!/usr/bin/env bash
# One-shot setup for the i3 rice. Idempotent — safe to re-run.
# Installs only what's missing, links configs, enables mpd services.
#
# Usage:   ./setup.sh
#          ./setup.sh --dry-run       # only report what would be done

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# An unrecognised argument is an error, not a silent full install — a typo'd
# `--dryrun` would otherwise apt-install and symlink over ~/.config.
usage() { printf 'usage: %s [--dry-run]\n' "${0##*/}" >&2; exit 2; }
DRY_RUN=false
case "${1:-}" in
    '')        ;;
    --dry-run) DRY_RUN=true ;;
    *)         usage ;;
esac
[[ $# -le 1 ]] || usage

# ── Colors ────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
    C_RED=$'\033[1;31m';  C_DIM=$'\033[2m';       C_OFF=$'\033[0m'
else
    C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''; C_OFF=''
fi

step()  { printf '%s▸%s %s\n' "$C_BLUE"  "$C_OFF" "$*"; }
ok()    { printf '%s✓%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
skip()  { printf '%s·%s %s%s%s\n' "$C_DIM" "$C_OFF" "$C_DIM" "$*" "$C_OFF"; }
# warn goes to stderr: every non-fatal failure here still exits 0, so on stdout
# a run where the bar failed to build looks identical to a clean one.
warn()  { printf '%s!%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
fail()  { printf '%s✗%s %s\n' "$C_RED"   "$C_OFF" "$*" >&2; }

run() {
    if $DRY_RUN; then
        printf '%s  would run:%s %s\n' "$C_DIM" "$C_OFF" "$*"
    else
        "$@"
    fi
}

# True when a privileged command can go through right now. Needed because
# best-linux-environment's boot.sh re-enters this from cron with no terminal,
# where a failing `sudo apt install` would take `set -e` and the rest with it.
can_sudo() {
    [[ $EUID -eq 0 ]] && return 0
    command -v sudo >/dev/null 2>&1 || return 1
    [[ -t 0 ]] || sudo -n true 2>/dev/null
}

# ── 0. Sanity ─────────────────────────────────────────────────────────────
if [[ ! -f "$REPO/config" ]]; then
    fail "Can't find i3 config at $REPO/config — are you running from the repo root?"
    exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
    fail "This script targets Debian/Ubuntu (apt). Adapt for your distro."
    exit 1
fi

# `config` has no way to name its own directory, so its exec lines say ~/.i3rc
# literally — installing elsewhere half-works at runtime. Compared on *resolved*
# paths, since $REPO is whatever spelling the caller used to get here.
if [[ "$(realpath -m "$HOME/.i3rc" 2>/dev/null)" != "$(realpath -m "$REPO")" ]]; then
    fail "This repo has to live at ~/.i3rc (found: $REPO)."
    fail "i3's config format cannot reference its own directory, so the exec"
    fail "lines in \`config\` name that path literally. Move or symlink the"
    # -n so an existing symlink is replaced, not followed — plain `ln -s` drops
    # the new link *inside* the directory it points at.
    fail "clone: ln -sfn \"$REPO\" \"$HOME/.i3rc\""
    exit 1
fi

# Canonical from here on: §3 writes this path into ~/.config/i3/config, so it
# must match the ~/.i3rc that `config`'s exec lines name.
REPO="$HOME/.i3rc"

# ── 1. apt packages ───────────────────────────────────────────────────────
step "Checking apt packages"

PACKAGES=(
    i3 i3lock
    rofi
    qalc                     # CLI calculator; nothing here calls it
    # Bound in `config`: $mod+Return / $mod+m (alacritty, also rofi's terminal),
    # $mod+Shift+s (flameshot) and $mod+b (firefox).
    alacritty flameshot firefox
    git build-essential pkg-config
    libgtk-3-dev libdbusmenu-gtk3-dev
    jq
    picom
    # feh sets the root background; xsetroot does not work under picom.
    feh
    dunst libnotify-bin
    network-manager-gnome blueman
    pavucontrol brightnessctl playerctl pulseaudio-utils
    wireplumber
    mpd mpc ncmpcpp mpdris2
    dex xss-lock
    # Papirus is named by rofi/dunst, Yaru by gtk/settings.ini. Yaru is only
    # missing on a minimal install, where tray menus fall back to hicolor.
    papirus-icon-theme yaru-theme-icon
    curl unzip xz-utils
    iw
    x11-xserver-utils x11-xkb-utils
    xbanish
)

# One dpkg-query for the whole list: `dpkg -s` is 4.97s here, and it exits 0 for
# an apt-removed-but-not-purged package. `db:Status-Status` tells the two apart.
declare -A pkg_status=()
while read -r _pkg _status; do pkg_status["$_pkg"]=$_status; done < <(
    dpkg-query -W -f='${Package} ${db:Status-Status}\n' "${PACKAGES[@]}" 2>/dev/null)

unknown=()
for pkg in "${PACKAGES[@]}"; do
    [[ "${pkg_status[$pkg]:-}" == installed ]] || unknown+=("$pkg")
done

# One apt-cache call for the lot — it pays ~0.9s of index startup per invocation.
# Parsed by block: `name:` at column 0, its Candidate line indented under it.
missing=()
if [[ ${#unknown[@]} -gt 0 ]]; then
    declare -A has_candidate=()
    cur=""
    while read -r line; do
        case "$line" in
            [!\ ]*:)      cur=${line%:} ;;
            *Candidate:*) [[ "${line##*Candidate: }" != "(none)" ]] && has_candidate["$cur"]=1 ;;
        esac
    done < <(apt-cache policy "${unknown[@]}" 2>/dev/null)
    for pkg in "${unknown[@]}"; do
        if [[ -n "${has_candidate[$pkg]:-}" ]]; then
            missing+=("$pkg")
        else
            warn "Package '$pkg' not available on this system — skipping."
        fi
    done
fi

if [[ ${#missing[@]} -eq 0 ]]; then
    skip "All apt packages already installed."
else
    step "Installing ${#missing[@]} missing package(s): ${missing[*]}"
    # Three outcomes, each reported as itself — a dry run and a skipped install
    # must not both print "apt packages installed".
    if $DRY_RUN; then
        printf '%s  would install:%s %s\n' "$C_DIM" "$C_OFF" "${missing[*]}"
    elif ! can_sudo; then
        # Not a failure: everything after this needs no privileges.
        warn "sudo unavailable (non-interactive) — skipped apt install: ${missing[*]}"
        warn "Run ~/.i3rc/setup.sh from a terminal to pick these up."
    else
        # A broken third-party PPA makes this exit non-zero; the install still
        # works against the cached indexes, so don't let `set -e` end the run.
        sudo apt update || warn "apt update reported errors (likely a stale PPA) — continuing."
        if sudo apt install -y "${missing[@]}"; then
            ok "apt packages installed."
        else
            warn "apt install failed — install these yourself: ${missing[*]}"
        fi
    fi
fi

# The font (Cascadia Code) and the cursor theme are cross-cutting and owned by
# best-linux-environment (basic/50-fonts-cursor.sh), not here.

# ── 2. eww bar (built from source — not packaged for Ubuntu) ──────────────
step "Checking eww"

# Pinned: the bar needs post-v0.6.0 master (`systray`, `:prepend-new`,
# `:reserve`), and untracked master compiles fine then breaks the bar at runtime.
EWW_REV=48f5aa8b379adf29da0b0bb9ca04164f65d8bdaa
EWW_BIN="$HOME/.local/bin/eww"
EWW_SRC="$HOME/.local/src/eww"
# What $EWW_BIN was built from — every master build still reports 0.6.0, so the
# check below cannot be `[[ -x $EWW_BIN ]]` or pre-pin installs never update.
EWW_REV_FILE="$HOME/.local/bin/.eww-rev"

eww_build() {
    # Deliberately unpinned, unlike eww: this is upstream's documented install,
    # and the bar's behaviour depends on the eww revision, not the toolchain.
    if ! command -v cargo >/dev/null 2>&1 && [[ ! -x "$HOME/.cargo/bin/cargo" ]]; then
        step "Installing Rust toolchain (rustup, user-local)"
        run bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable' || return 1
    fi
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env" 2>/dev/null || true

    if [[ ! -d "$EWW_SRC/.git" ]]; then
        step "Cloning eww"
        run mkdir -p "$EWW_SRC" || return 1
        run git -C "$EWW_SRC" init -q || return 1
        run git -C "$EWW_SRC" remote add origin https://github.com/elkowar/eww.git || return 1
    fi
    # Fetching the sha keeps this shallow (a full clone is ~60MB) and moves an
    # older unpinned clone onto the pin; git verifies the object hashes to it.
    step "Checking out eww at ${EWW_REV:0:7}"
    run git -C "$EWW_SRC" fetch -q --depth 1 origin "$EWW_REV" || return 1
    run git -C "$EWW_SRC" checkout -q --detach FETCH_HEAD || return 1
    step "Building eww (release, X11 only) — takes a few minutes"
    run bash -c "cd '$EWW_SRC' && cargo build --release --no-default-features --features x11" || return 1
    run mkdir -p "$HOME/.local/bin" || return 1
    # Copy beside the target then rename over it: a plain `cp` onto the binary a
    # running daemon was exec'd from gets ETXTBSY, which is the normal case here.
    run cp "$EWW_SRC/target/release/eww" "$EWW_BIN.new" || return 1
    run mv -f "$EWW_BIN.new" "$EWW_BIN" || return 1
    # Recorded last: a build that died halfway must not look complete next run.
    if $DRY_RUN; then
        printf '%s  would record:%s %s → %s\n' "$C_DIM" "$C_OFF" "$EWW_REV" "$EWW_REV_FILE"
    else
        printf '%s\n' "$EWW_REV" >"$EWW_REV_FILE"
    fi
}

if [[ -x "$EWW_BIN" ]] && [[ "$(cat "$EWW_REV_FILE" 2>/dev/null)" == "$EWW_REV" ]]; then
    skip "eww already at ${EWW_REV:0:7}."
# Non-fatal, unlike every other step: it is the only one needing the network and
# a Rust toolchain, and §3-§6 must still run without it.
elif eww_build; then
    ok "eww ${EWW_REV:0:7} installed to $EWW_BIN."
else
    warn "eww build failed — continuing with the rest of the setup."
    warn "  Re-run ./setup.sh to retry; until then the top bar will not start."
fi

# The blueman tray icon stays enabled: scripts/bluetooth_menu.sh is an
# alternative but is bound to nothing, so disabling it leaves no way in.

# ── 3. i3 include ─────────────────────────────────────────────────────────
step "Wiring ~/.config/i3/config → $REPO/config"

I3_CONFIG_DIR="$HOME/.config/i3"
I3_CONFIG_FILE="$I3_CONFIG_DIR/config"
INCLUDE_LINE="include \"$REPO/config\""

run mkdir -p "$I3_CONFIG_DIR"

# The config includes this file to recolor the focused border in resize mode
# (scripts/resize_border.sh). Create it empty so the include never errors.
run mkdir -p "$HOME/.cache/i3"
[[ -f "$HOME/.cache/i3/focus-override.conf" ]] || run touch "$HOME/.cache/i3/focus-override.conf"

# Detect an existing include in any spelling i3 accepts (absolute, ~, $HOME,
# quoted or bare) — missing one appends a second and i3 parses this twice.
# Whole lines, not substrings: a grep also matches `config.local` and comments.
already_wired=false
if [[ -f "$I3_CONFIG_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"          # ltrim
        line="${line%"${line##*[![:space:]]}"}"          # rtrim
        [[ "$line" == include[[:space:]]* ]] || continue # skips comments too
        path="${line#include}"
        path="${path#"${path%%[![:space:]]*}"}"
        [[ "$path" == \"*\" ]] && path="${path:1:${#path}-2}"
        for candidate in "$HOME/.i3rc/config" "~/.i3rc/config" "\$HOME/.i3rc/config" "$REPO/config"; do
            if [[ "$path" == "$candidate" ]]; then
                already_wired=true
                break 2
            fi
        done
    done < "$I3_CONFIG_FILE"
fi

if $already_wired; then
    skip "i3 config already includes repo."
elif [[ -s "$I3_CONFIG_FILE" ]]; then
    # Appended, never overwritten — truncating would discard the user's own
    # bindings. i3 applies later directives last, so this still has final say.
    backup="$I3_CONFIG_FILE.backup.$(date +%s)"
    warn "Existing i3 config found — backing up to $backup, then appending the include"
    run cp "$I3_CONFIG_FILE" "$backup"
    if $DRY_RUN; then
        printf '%s  would append:%s %s → %s\n' "$C_DIM" "$C_OFF" "$INCLUDE_LINE" "$I3_CONFIG_FILE"
    else
        printf '\n# Added by ~/.i3rc/setup.sh\n%s\n' "$INCLUDE_LINE" >> "$I3_CONFIG_FILE"
    fi
    ok "i3 config include appended (your previous settings are still above it)."
else
    if $DRY_RUN; then
        printf '%s  would write:%s %s → %s\n' "$C_DIM" "$C_OFF" "$INCLUDE_LINE" "$I3_CONFIG_FILE"
    else
        printf '%s\n' "$INCLUDE_LINE" > "$I3_CONFIG_FILE"
    fi
    ok "i3 config wired."
fi

# ── 4. Symlinks into ~/.config ────────────────────────────────────────────
step "Linking per-tool configs"

link() {
    local src="$1" dst="$2"
    run mkdir -p "$(dirname "$dst")"
    if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
        skip "$dst already linked."
        return
    fi
    # `|| -L` covers what `-e` misses: a link to somewhere else (stow/chezmoi)
    # and a dangling one, both of which would be clobbered with no backup.
    if [[ -e "$dst" || -L "$dst" ]]; then
        local backup="$dst.backup.$(date +%s)"
        warn "$dst exists — backing up to $backup"
        run mv "$dst" "$backup"
    fi
    run ln -sfn "$src" "$dst"
    ok "linked $dst"
}

link "$REPO/rofi/config.rasi"     "$HOME/.config/rofi/config.rasi"
link "$REPO/rofi/launcher.rasi"   "$HOME/.config/rofi/launcher.rasi"
link "$REPO/rofi/powermenu.rasi"  "$HOME/.config/rofi/powermenu.rasi"
link "$REPO/picom/picom.conf"     "$HOME/.config/picom/picom.conf"
link "$REPO/dunst/dunstrc"        "$HOME/.config/dunst/dunstrc"
link "$REPO/mpd/mpd.conf"         "$HOME/.config/mpd/mpd.conf"
link "$REPO/ncmpcpp/config"       "$HOME/.config/ncmpcpp/config"
# GTK menu theming (nm-applet, blueman tray menus) — Gruvbox restyle
link "$REPO/gtk/gtk.css"          "$HOME/.config/gtk-3.0/gtk.css"
link "$REPO/gtk/settings.ini"     "$HOME/.config/gtk-3.0/settings.ini"
link "$REPO/gtk/gtk.css"          "$HOME/.config/gtk-4.0/gtk.css"
link "$REPO/gtk/settings.ini"     "$HOME/.config/gtk-4.0/settings.ini"

# ── 5. Make scripts executable ────────────────────────────────────────────
# Keep new scripts committed 755 so this stays a no-op: a 644 file gets flipped
# here, dirties the tree with a mode change, and aborts install.sh's `git pull`.
step "Ensuring scripts are executable"
run chmod +x "$REPO"/scripts/*.sh "$REPO"/eww/scripts/*.sh
ok "scripts ready."

# ── 5b. Alacritty theme import ────────────────────────────────────────────
# $mod+Shift+t writes a theme file that does nothing unless Alacritty's own
# config imports it — not ours to edit, so report the gap instead.
step "Checking the Alacritty theme import"

# shellcheck source=scripts/theme_lib.sh
source "$REPO/scripts/theme_lib.sh"

alacritty_cfg="$(alacritty_config)" || alacritty_cfg=""

if [[ -z "$alacritty_cfg" ]]; then
    skip "No Alacritty config found — \$mod+Shift+t will have nothing to theme."
elif alacritty_imports_theme "$alacritty_cfg"; then
    skip "Alacritty already imports the theme file."
else
    warn "$alacritty_cfg does not import ~/.cache/alacritty-theme.toml —"
    warn "  \$mod+Shift+t writes the theme but nothing reads it. Add:"
    warn "      [general]"
    warn "      import = [\"~/.cache/alacritty-theme.toml\"]"
    warn "  and drop any inline [colors] there: values in the importing file"
    warn "  win over imported ones, so they would override the theme. (§9)"
fi

# Seed the theme file, or a fresh install comes up in Alacritty's own palette
# until the first toggle. Only when missing — rewriting it would undo a choice
# of light on every run. Mode from theme.sh's state file if there is one.
if [[ ! -f "$ALACRITTY_THEME_FILE" ]]; then
    theme_mode="$(cat "$HOME/.cache/theme-mode" 2>/dev/null || true)"
    case "$theme_mode" in
        dark|light) ;;
        *) theme_mode=dark ;;
    esac
    step "Seeding the $theme_mode terminal theme (first run — none written yet)"
    run "$REPO/scripts/theme.sh" "$theme_mode" \
        || warn "Could not write the theme file — press \$mod+Shift+t twice to generate it."
else
    skip "Terminal theme file already written."
fi

# ── 6. mpd directories + services ─────────────────────────────────────────
step "Setting up mpd"

run mkdir -p "$HOME/.local/share/mpd/playlists"

if command -v systemctl >/dev/null 2>&1; then
    # mpd user service
    if systemctl --user is-enabled mpd.service >/dev/null 2>&1 &&
       systemctl --user is-active  mpd.service >/dev/null 2>&1; then
        skip "mpd.service already enabled + running."
    else
        run systemctl --user enable --now mpd.service || warn "Could not enable mpd.service"
    fi

    # mpdris2 bridge (case varies between packagings)
    enabled_any=false
    for svc in mpdris2.service mpDris2.service; do
        if systemctl --user list-unit-files "$svc" 2>/dev/null | grep -Fq "$svc"; then
            if systemctl --user is-enabled "$svc" >/dev/null 2>&1; then
                skip "$svc already enabled."
            else
                run systemctl --user enable --now "$svc" || true
            fi
            enabled_any=true
            break
        fi
    done
    $enabled_any || warn "mpdris2 service unit not found — bar music titles may not appear."
else
    warn "systemctl not available — start mpd and mpdris2 manually."
fi

# First library scan (non-fatal).
if command -v mpc >/dev/null 2>&1; then
    step "Kicking off mpd library scan"
    run mpc update >/dev/null 2>&1 || warn "mpc update failed — music folder may be empty or mpd not running yet."
fi

# ── 7. Done ───────────────────────────────────────────────────────────────
echo
ok "Setup complete."
echo
echo "Next: log into i3, then press  ${C_BLUE}\$mod+Shift+r${C_OFF}  to restart."
echo "If you're on another WM right now, log out and pick 'i3' at the login screen."
