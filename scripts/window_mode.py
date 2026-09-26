#!/usr/bin/env python3
# The $mod+r window mode: resize and move a floating window, resize a tiled one.
# hjkl pushes an edge out, HJKL pulls the same edge in, the arrows move a
# floating window without changing its size.
#
# One resident daemon, started by exec_always, not a script per keypress. The
# keys are `nop window_mode …` bindings, so each press reaches us as an i3
# binding event: no process spawned, nothing to fork, a key costs well under a
# millisecond. Holding a key at 50 repeats/s used to queue 40ms scripts behind
# each other, and the window kept moving after the key was up.
#
# The window itself is not resized on every press. A translucent box shows the
# frame the window *will* have and follows the keys instantly; the real
# `resize set` / `move position` goes out once the keys pause (DEBOUNCE_MS) and,
# while a key is held, at most every MAX_WAIT_MS. So the app re-lays out and
# picom repaints a handful of times per gesture instead of fifty times a second.
# The box is also the mode cue — it replaces the thick border the mode used to
# put on, which cost the window two re-layouts of its own.
#
# Growing and moving stop at the usable workspace — the rect i3 has already
# shrunk by the bar's strut — so a floating window can never end up off the
# monitor. Shrinking is never blocked, down to MIN_W x MIN_H.
#   window_mode.py watch   — from exec_always; the bindings do the rest
import glob
import json
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import time

import cairo
import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

# GLib 2.80 moved the Unix signal sources into their own namespace.
try:
    gi.require_version("GLibUnix", "2.0")
    from gi.repository import GLibUnix  # noqa: E402
    signal_add = GLibUnix.signal_add
except (ValueError, ImportError):
    signal_add = GLib.unix_signal_add

# Pixels one keypress moves an edge, and the smallest frame a window can shrink
# to — below that a window is a stub you can no longer aim at with the mouse.
STEP_PX = int(os.environ.get("I3RC_MODE_STEP_PX", 20))
MIN_W = int(os.environ.get("I3RC_MODE_MIN_W", 120))
MIN_H = int(os.environ.get("I3RC_MODE_MIN_H", 80))

# When the pending keys are sent to i3: after this long with no key, and never
# later than MAX_WAIT after the first unsent one. Tiled has no preview to lean
# on (i3 decides how the neighbours give way), so it flushes sooner.
DEBOUNCE_MS = {"floating": 80, "tiled": 40}
MAX_WAIT_MS = {"floating": 250, "tiled": 80}
# The box re-reads the real frame this often while idle: a mouse drag mid-mode
# has no key event, and i3 may snap a size to the app's hints.
SYNC_MS = 200

BOX_OUTLINE_PX = 4
BOX_FILL_ALPHA = 0.45
DEFAULT_COLOUR = "#d3869b"

MAGIC = b"i3-ipc"
RUN_COMMAND, SUBSCRIBE, GET_TREE = 0, 2, 4
EVENT_BIT = 1 << 31
EV_MODE, EV_WINDOW, EV_BINDING = 2, 3, 5


# ── i3 IPC ──────────────────────────────────────────────────────────────────
class Ipc:
    """One connection. Two are used: requests on one, the event stream on the other."""

    def __init__(self):
        path = os.environ.get("I3SOCK") or subprocess.check_output(
            ["i3", "--get-socketpath"], text=True).strip()
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)

    def send(self, kind, payload=""):
        data = payload.encode()
        self.sock.sendall(MAGIC + struct.pack("=II", len(data), kind) + data)

    def _exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise EOFError
            buf += chunk
        return buf

    def recv(self):
        head = self._exact(len(MAGIC) + 8)
        length, kind = struct.unpack("=II", head[len(MAGIC):])
        return kind, json.loads(self._exact(length) or b"null")

    def request(self, kind, payload=""):
        self.send(kind, payload)
        return self.recv()[1]

    def command(self, cmd):
        return self.request(RUN_COMMAND, cmd)

    def tree(self):
        return self.request(GET_TREE)


def walk(node):
    yield node
    for key in ("nodes", "floating_nodes"):
        for child in node.get(key, ()):
            yield from walk(child)


def rect(r):
    return (r["x"], r["y"], r["width"], r["height"])


def locate(tree, con_id=None):
    """(con, floating, frame, workspace rect) for con_id, or for the focused con.

    The frame is what `resize set` and `move position` speak in: the floating_con
    for a floating window, the con's own rect for a tiled one."""
    def hit(con):
        if con.get("id") is None:
            return False
        return bool(con.get("focused")) if con_id is None else con["id"] == con_id

    for ws in walk(tree):
        if ws.get("type") != "workspace":
            continue
        for fc in ws.get("floating_nodes", ()):
            for con in walk(fc):
                if con is not fc and hit(con):
                    return con, True, rect(fc["rect"]), rect(ws["rect"])
        for top in ws.get("nodes", ()):
            for con in walk(top):
                if hit(con):
                    return con, False, rect(con["rect"]), rect(ws["rect"])
    return None


def focused_colour():
    """client.focused's border colour, the way i3 reads it: config first, then
    every *.local in glob order, last line wins."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    colour = DEFAULT_COLOUR
    for path in [os.path.join(root, "config")] + sorted(glob.glob(os.path.join(root, "*.local"))):
        try:
            with open(path) as f:
                for line in f:
                    m = re.match(r"\s*client\.focused\s+(#[0-9a-fA-F]{6})", line)
                    if m:
                        colour = m.group(1)
        except OSError:
            pass
    v = int(colour[1:], 16)
    return ((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255


# ── Preview box ─────────────────────────────────────────────────────────────
class Box:
    """A click-through override-redirect window drawn as a tinted frame."""

    def __init__(self):
        self.rgb = focused_colour()
        self.win = Gtk.Window(type=Gtk.WindowType.POPUP)  # i3 leaves it alone
        screen = self.win.get_screen()
        self.alpha = screen.is_composited() and screen.get_rgba_visual() is not None
        if self.alpha:
            self.win.set_visual(screen.get_rgba_visual())
        self.win.set_app_paintable(True)
        self.win.connect("draw", self.draw)
        self.win.realize()
        # Empty input shape: clicks fall through, so the border stays a resize handle.
        self.win.get_window().input_shape_combine_region(cairo.Region(), 0, 0)
        self.geo = None

    def draw(self, widget, cr):
        w, h = widget.get_allocated_width(), widget.get_allocated_height()
        r, g, b = self.rgb
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(r, g, b, BOX_FILL_ALPHA if self.alpha else 1.0)
        cr.paint()
        cr.set_source_rgba(r, g, b, 1.0)
        cr.set_line_width(BOX_OUTLINE_PX)
        cr.rectangle(BOX_OUTLINE_PX / 2, BOX_OUTLINE_PX / 2, w - BOX_OUTLINE_PX, h - BOX_OUTLINE_PX)
        cr.stroke()
        return True

    def show(self, geo):
        x, y, w, h = geo
        if geo != self.geo:
            self.geo = geo
            self.win.move(x, y)
            self.win.resize(max(1, w), max(1, h))
        self.win.show()
        # i3 puts a moved floating frame back on top, which would bury us.
        self.win.get_window().raise_()

    def hide(self):
        self.geo = None
        self.win.hide()


# ── The mode ────────────────────────────────────────────────────────────────
class Mode:
    def __init__(self, ipc):
        self.ipc = ipc
        self.box = Box()
        self.con_id = None
        self.floating = False
        self.frame = None          # the box: where the window will be
        self.ws = None             # usable workspace rect
        self.pending = None        # floating: True; tiled: {(way, dir): count}
        self.first_pending = 0.0
        self.flush_src = None
        self.sync_src = None

    @property
    def kind(self):
        return "floating" if self.floating else "tiled"

    @property
    def active(self):
        return self.con_id is not None

    # -- lifecycle --------------------------------------------------------
    def on(self):
        if self.active:
            self.off()
            return
        found = locate(self.ipc.tree())
        if not found:
            return
        con, self.floating, self.frame, self.ws = found
        self.con_id = con["id"]
        self.box.show(self.frame)
        self.ipc.command('mode "resize floating"' if self.floating else 'mode "resize"')
        self.sync_src = GLib.timeout_add(SYNC_MS, self.sync)

    def off(self, tell_i3=True):
        if not self.active:
            return
        self.flush()
        self.con_id = None
        self.box.hide()
        for attr in ("sync_src", "flush_src"):
            if getattr(self, attr):
                GLib.source_remove(getattr(self, attr))
                setattr(self, attr, None)
        if tell_i3:
            self.ipc.command("mode default")

    def sync(self):
        """Box <- real frame, unless keys are still waiting to be sent."""
        if not self.active:
            return False
        if self.pending:
            return True
        found = locate(self.ipc.tree(), self.con_id)
        if not found:
            self.off()
            return False
        _, floating, self.frame, self.ws = found
        if floating != self.floating:
            # Tiled <-> floated mid-mode ($mod+Shift+space): follow the window.
            self.floating = floating
            self.ipc.command('mode "resize floating"' if floating else 'mode "resize"')
        self.box.show(self.frame)
        return True

    # -- keys -------------------------------------------------------------
    def key(self, words):
        if not self.active:
            return
        how, dir_ = words[0], words[1] if len(words) > 1 else ""
        if self.floating:
            self.step_floating(how, dir_)
        else:
            self.step_tiled(how, dir_)

    def step_floating(self, how, dir_):
        wx, wy, ww, wh = self.ws
        x, y, w, h = self.frame
        s = STEP_PX
        nx, ny, nw, nh = x, y, w, h
        if how == "grow":
            # Clamped on the workspace edge, so an edge already off-screen
            # comes back to it instead of running further out.
            if dir_ == "left":
                nx = max(wx, x - s); nw = w + x - nx
            elif dir_ == "up":
                ny = max(wy, y - s); nh = h + y - ny
            elif dir_ == "right":
                nw = min(w + s, wx + ww - x)
            elif dir_ == "down":
                nh = min(h + s, wy + wh - y)
        elif how == "shrink":
            # Pulls the same edge in: `left` walks the left edge right, so the
            # window loses width on its left side and the right edge stays put.
            if dir_ == "left":
                nw = max(MIN_W, w - s); nx = x + w - nw
            elif dir_ == "up":
                nh = max(MIN_H, h - s); ny = y + h - nh
            elif dir_ == "right":
                nw = max(MIN_W, w - s)
            elif dir_ == "down":
                nh = max(MIN_H, h - s)
        elif how == "move":
            # Size kept, clamped on the workspace: the window stops flush against
            # the edge. A window bigger than the workspace pins to the top-left.
            if dir_ == "left":
                nx = max(wx, x - s)
            elif dir_ == "up":
                ny = max(wy, y - s)
            elif dir_ == "right":
                nx = max(wx, min(x + s, wx + ww - w))
            elif dir_ == "down":
                ny = max(wy, min(y + s, wy + wh - h))
        else:
            return
        if (nx, ny, nw, nh) == (x, y, w, h):
            return
        self.frame = (nx, ny, nw, nh)
        self.box.show(self.frame)
        self.queue(True)

    def step_tiled(self, how, dir_):
        # i3's own semantics, coalesced: N presses become one `resize … N*STEP px`.
        # A px-only resize on a tiled container is turned into a share by i3.
        if how not in ("grow", "shrink") or dir_ not in ("width", "height", "left", "right", "up", "down"):
            return
        pend = self.pending if isinstance(self.pending, dict) else {}
        pend[(how, dir_)] = pend.get((how, dir_), 0) + 1
        self.queue(pend)

    # -- sending ----------------------------------------------------------
    def queue(self, pending):
        now = time.monotonic()
        if not self.pending:
            self.first_pending = now
        self.pending = pending
        if self.flush_src:
            GLib.source_remove(self.flush_src)
            self.flush_src = None
        if (now - self.first_pending) * 1000 >= MAX_WAIT_MS[self.kind]:
            self.flush()
        else:
            self.flush_src = GLib.timeout_add(DEBOUNCE_MS[self.kind], self.flush)

    def flush(self):
        if self.flush_src:
            GLib.source_remove(self.flush_src)
            self.flush_src = None
        pending, self.pending = self.pending, None
        if not pending or not self.active:
            return False
        cid = self.con_id
        if self.floating:
            x, y, w, h = self.frame
            # Two commands, one round trip, resize first: `move position` on the
            # old size would land the frame wrong for every grow that moves an edge.
            self.ipc.command(f"[con_id={cid}] resize set {w} px {h} px; "
                             f"[con_id={cid}] move position {x} px {y} px")
        else:
            self.ipc.command("; ".join(
                f"[con_id={cid}] resize {how} {dir_} {n * STEP_PX} px"
                for (how, dir_), n in pending.items()))
        # The box takes the frame i3 really gave (size hints, a neighbour that
        # would not shrink) so the preview never drifts from the window.
        found = locate(self.ipc.tree(), cid)
        if found:
            _, _, self.frame, self.ws = found
            self.box.show(self.frame)
        return False

    # -- events -----------------------------------------------------------
    def event(self, kind, ev):
        if kind == EV_BINDING:
            words = (ev.get("binding") or {}).get("command", "").split()
            if len(words) >= 3 and words[0] == "nop" and words[1] == "window_mode":
                if words[2] == "on":
                    self.on()
                elif words[2] == "off":
                    self.off()
                else:
                    self.key(words[2:])
        elif kind == EV_MODE:
            # Left by someone else (a `mode default` from a script): just follow.
            if ev.get("change") == "default" and self.active:
                self.off(tell_i3=False)
        elif kind == EV_WINDOW and self.active:
            con = ev.get("container") or {}
            if con.get("id") != self.con_id:
                return
            if ev.get("change") == "close":
                self.off()
            elif ev.get("change") in ("move", "floating", "focus") and not self.pending:
                self.sync()


# ── Daemon plumbing ─────────────────────────────────────────────────────────
def runtime_dir():
    # Same rule as runtime_lib.sh: never /tmp, $HOME fallback survives reboots.
    d = os.environ.get("XDG_RUNTIME_DIR")
    if not d or not os.path.isdir(d):
        d = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "i3rc")
        os.makedirs(d, exist_ok=True)
    return d


def take_pidfile(path):
    """exec_always re-runs us on every i3 restart: stop the copy before us, but
    only a process really running this script — never a stranger with our pid."""
    try:
        with open(path) as f:
            old = int(f.read().strip() or 0)
        with open(f"/proc/{old}/cmdline", "rb") as f:
            if old != os.getpid() and b"window_mode.py" in f.read():
                os.kill(old, signal.SIGTERM)
    except (OSError, ValueError):
        pass
    with open(path, "w") as f:
        f.write(f"{os.getpid()}\n")


def release_pidfile(path):
    try:
        with open(path) as f:
            if int(f.read().strip() or 0) == os.getpid():
                os.unlink(path)
    except (OSError, ValueError):
        pass


def watch():
    pidfile = os.path.join(runtime_dir(), "i3rc-window-mode.pid")
    take_pidfile(pidfile)

    cmd, events = Ipc(), Ipc()
    events.request(SUBSCRIBE, json.dumps(["binding", "mode", "window"]))
    mode = Mode(cmd)

    def on_event(fd, cond):
        if cond & (GLib.IO_HUP | GLib.IO_ERR):
            Gtk.main_quit()
            return False
        try:
            kind, ev = events.recv()
        except EOFError:
            Gtk.main_quit()
            return False
        if kind & EVENT_BIT:
            try:
                mode.event(kind & ~EVENT_BIT, ev)
            except (OSError, EOFError):
                Gtk.main_quit()
                return False
        return True

    def quit_(*_):
        try:
            mode.off()
        except Exception:  # noqa: BLE001 — i3 may already be gone
            pass
        Gtk.main_quit()
        return False

    GLib.io_add_watch(events.sock.fileno(), GLib.PRIORITY_HIGH,
                      GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, on_event)
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal_add(GLib.PRIORITY_HIGH, sig, quit_)
    try:
        Gtk.main()
    finally:
        release_pidfile(pidfile)


if __name__ == "__main__":
    if sys.argv[1:] != ["watch"]:
        print(f"usage: {os.path.basename(sys.argv[0])} watch", file=sys.stderr)
        sys.exit(2)
    watch()
