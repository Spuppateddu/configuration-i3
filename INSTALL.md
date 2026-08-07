# Install guide — i3 rice

Full setup for this i3 configuration on a fresh Ubuntu (tested on 25.10). At
the end you get: i3 with gaps + Gruvbox colors, an eww top bar (built from
source), rofi
launcher, a solid Gruvbox-dark background, picom compositing, dunst notifications,
and mpd + ncmpcpp for music with controls in the top bar.

## TL;DR — one command

```bash
git clone <this-repo> ~/.i3rc
cd ~/.i3rc
./setup.sh
```

The script is idempotent: it checks what's already installed and only does
the missing work (apt packages, eww build from source, config symlinks, mpd
user services). Re-run it anytime. `./setup.sh --dry-run` shows what would
change without touching anything.

The font (Courier Prime — the only one this repo names) and the cursor theme are
**not** installed by `setup.sh` — they are cross-cutting (terminal, editor, bar)
and owned by *best-linux-environment*. Install the font by hand with §3 if you
are using this repo standalone.

The sections below explain each step manually if you want to do it by hand
or understand what `setup.sh` is doing.

## 1. Clone the repo

```bash
git clone <this-repo> ~/.i3rc
```

Then tell i3 to use it:

```bash
mkdir -p ~/.config/i3
printf 'include "~/.i3rc/config"\n' > ~/.config/i3/config
```

## 2. Install packages

The canonical list is the `PACKAGES` array in [setup.sh](./setup.sh) — this
page used to restate it and had already drifted seven packages behind, so read
it from the source of truth instead:

```bash
sed -n '/^PACKAGES=(/,/^)/p' ~/.i3rc/setup.sh          # what gets installed
sudo apt update && sudo apt install -y $(sed -n '/^PACKAGES=(/,/^)/p' ~/.i3rc/setup.sh \
    | sed '1d;$d' | sed 's/#.*//')                      # install it by hand
```

`setup.sh` additionally skips anything with no installation candidate on your
release, which the raw `apt install` above will not do.

> The top bar is [eww](https://github.com/elkowar/eww), which is not packaged
> for Ubuntu — `setup.sh` installs a user-local Rust toolchain and builds it
> from a **pinned commit**. eww's last release (v0.6.0, 2023) predates
> `systray`, `:prepend-new` and `:reserve (struts …)`, so the bar needs master;
> but a plain `clone --depth 1` of master builds whatever upstream is that day,
> which compiles fine and then breaks the bar at runtime. Read the pin from the
> source of truth rather than copying it here, the way §2 does for `PACKAGES`:
>
> ```bash
> EWW_REV=$(sed -n 's/^EWW_REV=//p' ~/.i3rc/setup.sh)
> curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
> mkdir -p ~/.local/src/eww && cd ~/.local/src/eww
> git init -q && git remote add origin https://github.com/elkowar/eww.git
> git fetch -q --depth 1 origin "$EWW_REV" && git checkout -q --detach FETCH_HEAD
> cargo build --release --no-default-features --features x11
> mkdir -p ~/.local/bin && cp target/release/eww ~/.local/bin/eww
> printf '%s\n' "$EWW_REV" > ~/.local/bin/.eww-rev   # what setup.sh reads to know it can skip
> ```
>
> That last line matters: without it `setup.sh` sees an unknown build and
> rebuilds eww on its next run.

## 3. Font — Courier Prime

Every font line in this repo — `config`, `eww/eww.scss`, `rofi/*.rasi`,
`dunst/dunstrc`, `gtk/settings.ini` — names **one family and nothing else**:

```
Courier Prime
```

Courier Prime is a Courier — a 2013 redesign of the 1955 typewriter face. There
is deliberately no second family behind it: this repo is a single-font setup, so
whatever Courier Prime does not cover is not covered. The terminal
(`~/.alacritty/alacritty.toml`) and Firefox lead with the same Courier Prime, so
the three surfaces on screen at once agree.

**Why Courier Prime and not Courier New**, which this repo was briefly on: a
Courier reads thin on screen. The two ways out are a heavier weight or a heavier
design, and Courier New has nothing above Bold — so taking its Bold as the
everyday face would have collapsed bold-as-emphasis everywhere (dunst's `<b>`
summary, eww's `.header`, `<strong>` on the web). Courier Prime is the heavier
design, at Courier's identical 0.600 em advance, and keeps a real Bold on top.

The font is cross-cutting and owned by **`best-linux-environment`** —
`basic/50-fonts-cursor.sh` installs it, matching the note in this repo's
`setup.sh`. If you run that, skip this section. The manual equivalent, for a
standalone clone:

```bash
# Courier Prime — upstream's own TTFs. Do NOT use apt's fonts-courier-prime:
# that build (0+git20190115-4) labels all four faces style=Light, weight=50,
# slant=0, so fontconfig cannot tell Bold from Regular and Pango synthesises a
# smeared fake bold instead of using the real one.
mkdir -p ~/.local/share/fonts
curl -L -o /tmp/CourierPrime.zip \
  https://github.com/quoteunquoteapps/CourierPrime/archive/refs/heads/master.zip
unzip -oq /tmp/CourierPrime.zip -d /tmp/courierprime
cp /tmp/courierprime/CourierPrime-*/fonts/ttf/CourierPrime-*.ttf ~/.local/share/fonts/
fc-cache -fv
```

If `50-fonts-cursor.sh` (or anything else) has written a machine-wide
fontconfig default-family rule, make sure it carries an explicit exception for
Courier Prime — a rule that *prepends* another family in front of every pattern
wins over the lines above, and the desktop then renders as if they had never
been changed. If Courier Prime refuses to show up,
`~/.config/fontconfig/conf.d/` is the first place to look.

Verify:

```bash
fc-match "Courier Prime"                                  # must answer Courier Prime
# and the whole point of Courier Prime — four real faces, not one file four times:
for s in "" :bold :italic :bold:italic; do fc-match "Courier Prime$s" file; done
```

If a command prints nothing but the font is installed, the fontconfig cache is
stale — `fc-cache -rf` (a plain `fc-cache -f <dir>` may not be enough).

### Cursor theme

`gtk/settings.ini` asks for the `macOS` cursor theme, which `setup.sh` does not
install either — same reason as the font, it is cross-cutting and owned by
*best-linux-environment*. A missing cursor theme falls back silently to the
default, so check rather than assume:

```bash
ls -d ~/.icons/macOS /usr/share/icons/macOS 2>/dev/null   # installed?
```

If it prints nothing, either install an [apple-cursor](https://github.com/ful1e5/apple_cursor)
build into `~/.icons/`, or point `gtk-cursor-theme-name` in
[gtk/settings.ini](./gtk/settings.ini) at a theme you do have (`Adwaita` and
`Yaru` both ship with Ubuntu).

## 4. Link the per-tool configs into `~/.config`

This keeps all files tracked in `~/.i3rc` and each tool finds them in its
default location:

```bash
mkdir -p ~/.config/{rofi,picom,dunst,mpd,ncmpcpp,gtk-3.0,gtk-4.0}
ln -sf ~/.i3rc/rofi/config.rasi     ~/.config/rofi/config.rasi
ln -sf ~/.i3rc/rofi/launcher.rasi   ~/.config/rofi/launcher.rasi
ln -sf ~/.i3rc/rofi/powermenu.rasi  ~/.config/rofi/powermenu.rasi
ln -sf ~/.i3rc/picom/picom.conf     ~/.config/picom/picom.conf
ln -sf ~/.i3rc/dunst/dunstrc        ~/.config/dunst/dunstrc
ln -sf ~/.i3rc/mpd/mpd.conf         ~/.config/mpd/mpd.conf
ln -sf ~/.i3rc/ncmpcpp/config       ~/.config/ncmpcpp/config
# GTK menu theming (nm-applet, blueman tray menus)
ln -sf ~/.i3rc/gtk/gtk.css          ~/.config/gtk-3.0/gtk.css
ln -sf ~/.i3rc/gtk/settings.ini     ~/.config/gtk-3.0/settings.ini
ln -sf ~/.i3rc/gtk/gtk.css          ~/.config/gtk-4.0/gtk.css
ln -sf ~/.i3rc/gtk/settings.ini     ~/.config/gtk-4.0/settings.ini
```

`setup.sh` creates exactly this set (the `link` calls in §4 of that file); unlike
the bare `ln -sf` above it backs up whatever it finds in the way first.

The i3 config already references the in-repo paths directly for eww,
rofi, picom, and dunst, so the symlinks above are optional for those — they
only help if you later run the tools standalone (e.g. `rofi -show drun`
without passing `-config`). For mpd + ncmpcpp the symlinks **are** required,
since those daemons auto-load from `~/.config`.

## 5. Background

There is no wallpaper. `config` paints the root window the Gruvbox-dark
background (`#1d2021`) on every i3 start/reload:

```
exec_always --no-startup-id ~/.i3rc/scripts/set_background.sh
```

The script tiles a tiny solid-colour image with `feh`. It deliberately does
**not** use `xsetroot -solid`: with picom running as a compositor, picom
composites the `_XROOTPMAP_ID` root pixmap (the wallpaper set at login) and
ignores `xsetroot`. `feh` updates that pixmap, so the colour actually shows.
`feh` is installed by `setup.sh`.

## 6. Music (mpd + ncmpcpp)

Edit `~/.i3rc/mpd/mpd.conf` if your music folder is not `~/Music`,
then enable and start the **user** mpd service + MPRIS bridge:

```bash
mkdir -p ~/.local/share/mpd/playlists
systemctl --user enable --now mpd.service
systemctl --user enable --now mpDris2.service   # case varies; try both:
systemctl --user enable --now mpdris2.service || true
```

First library scan:

```bash
mpc update --wait
```

Controls:

| Action | Binding / Place |
|---|---|
| Open full TUI (random/queue/volume/etc.) | `$mod+m` |
| Rofi folder picker → queue + shuffle + play | `$mod+Shift+m` |
| Play / pause | Click the ▶ icon in the top bar |
| Prev / next | Click ⏮ / ⏭ in top bar |
| Hide / show the track name | **Click the title** — it collapses to an eye glyph |
| What is playing (full title + album) | **Right-click** the title |
| Media keys | XF86AudioPlay / Next / Prev (if your keyboard has them) |

The hide toggle is there because the bar is in every screenshot and every shared
screen, and the track name is the one thing on it that says what you are doing.
It resets to visible when the bar restarts.

The bar deliberately carries no shuffle or repeat toggle and no play-a-folder
button: those are queue-shaped controls and the queue belongs to ncmpcpp, while
the bar also has to speak for a browser tab, which has no queue at all. Inside
ncmpcpp the useful keys are: `z` = random, `r` = repeat, `c` = clear queue,
`+/-` = volume, `space` = enqueue, `p` = pause, `>/<` = next/prev, `/` = search,
`1/2/3/4` = switch panes.

## 6b. What the bar shows for a browser tab

The title tracks whatever is playing, not just mpd — a YouTube tab shows up with
its video title and channel, because Firefox publishes both over MPRIS. Playing
media always wins over paused. When everything is paused, the bar sticks with
whichever player was last actually playing, so pausing a video and pressing play
again resumes *that video* rather than handing the buttons back to a paused mpd.
Only if nothing has played yet does mpd win the tie.

Not every control reaches every player. Firefox reports `CanGoNext: false` for a
standalone YouTube video, so ⏮/⏭ do nothing there (they work inside a playlist,
and always for mpd). Play/pause and the title work everywhere. To check what a
given player actually offers:

```bash
playerctl -l                                     # who is on the bus
busctl --user get-property org.mpris.MediaPlayer2.<name> \
    /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player CanGoNext
```

## 7. First launch

Log out, pick **i3** at the login screen, log back in. Or if you're already
in i3: `$mod+Shift+r` to restart.

If the top bar doesn't appear:

```bash
~/.i3rc/scripts/launch_eww.sh
~/.local/bin/eww --config ~/.i3rc/eww logs            # live config/script errors
~/.local/bin/eww --config ~/.i3rc/eww active-windows  # should list "bar: bar"
```

## 8. Keybindings cheat sheet

| Keys | Action |
|---|---|
| `$mod+Return` | Terminal (alacritty) |
| `$mod+b` | Browser (firefox, new window) |
| `$mod+d` | App launcher (rofi) |
| `$mod+Tab` | Window switcher (rofi) |
| `$mod+q` | Kill focused window |
| `$mod+Shift+b` | Show/hide the top bar (eww) |
| `$mod+Shift+t` | Terminal light/dark toggle (see §9) |
| `$mod+Shift+s` | Screenshot (flameshot) |
| `$mod+Shift+x` | Lock screen |
| `$mod+Shift+p` | Power menu |
| `$mod+m` | Music TUI (ncmpcpp) |
| `$mod+Shift+m` | Pick a folder → shuffle play |
| `$mod+f` | Fullscreen |
| `$mod+h/j/k/l` | Focus left/down/up/right |
| `$mod+Shift+h/j/k/l` | Move window |
| `$mod+1..0` | Workspace 1..10 |
| `$mod+Shift+1..0` | Move window to workspace |
| `$mod+r` | Resize mode |
| `$mod+Shift+c` | Reload i3 |
| `$mod+Shift+r` | Restart i3 |
| `$mod+Shift+e` | Exit i3 |

`$mod` is the **Alt** key (`set $mod Mod1` in [config](./config)). Swap the two
`set $mod` lines at the top of that file to use Super (Windows) instead.

## 9. Customizing

- **Colors** — search `#282828` / `#fe8019` etc. The palette is Gruvbox
  Dark; swap values consistently across `eww/eww.scss`,
  `rofi/launcher.rasi`, `dunst/dunstrc`, and the `client.*` lines in
  `config`.
- **Bar widgets/layout** — edit `eww/eww.yuck` (widgets, islands) and
  `eww/eww.scss` (style); changes apply live with
  `~/.local/bin/eww --config ~/.i3rc/eww reload`.
- **Gaps** — `gaps inner`/`gaps outer` in `config`.
- **Background color** — the colour in `scripts/set_background.sh` (`config`
  runs it via the `set_background.sh` line).

### Terminal light/dark toggle (`$mod+Shift+t`)

`scripts/theme.sh` writes the scheme to `~/.cache/alacritty-theme.toml`. That
file does nothing on its own — **Alacritty's config has to import it**, and that
config is not part of this repo (it is yours, or *best-linux-environment*'s), so
neither `setup.sh` nor `theme.sh` will edit it for you. Both check and tell you
if the wiring is missing.

If your Alacritty config comes from the companion `configuration-alacritty` repo, this
is already done: it ships the `import` below, defines no colours of its own, and
`setup.sh` writes the theme file once on first run so the import is never empty.
The rest of this section is for a hand-rolled Alacritty config.

Add to your `alacritty.toml` (usually `~/.config/alacritty/alacritty.toml`):

```toml
[general]
import = ["~/.cache/alacritty-theme.toml"]
```

Then **remove any inline `[colors]` block and `[window] opacity`** from that
file. Alacritty gives the importing file precedence over what it imports, so
colors left in place override the theme and the toggle appears to do nothing.
`[general] import` is the Alacritty ≥ 0.14 spelling; older versions take a
top-level `import`.

## 10. Uninstall / revert

```bash
rm ~/.config/i3/config
# and/or re-point it to a default i3 config
```

Everything else is self-contained in `~/.i3rc` + the symlinks in
`~/.config/{rofi,picom,dunst,mpd,ncmpcpp}` (plus `~/.local/bin/eww` and
`~/.local/src/eww`).

The GTK links are the one thing that reaches past i3 — `gtk.css` and
`settings.ini` restyle **every** GTK app on the machine, not just the tray
menus, so leaving them behind makes the desktop look Gruvbox'd with nothing
left to explain why. Remove them too, and restore whatever `setup.sh` backed
up next to them:

```bash
rm ~/.config/gtk-3.0/{gtk.css,settings.ini} ~/.config/gtk-4.0/{gtk.css,settings.ini}
ls ~/.config/gtk-3.0/*.backup.* ~/.config/gtk-4.0/*.backup.*   # yours, if you had any
```
