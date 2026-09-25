#!/usr/bin/env python3
# Black dashes over a window's border while the $mod+r mode is on. i3 has no
# dashed style, so this is an overlay: a click-through window cut to the dashes.
#   mode_dashes.py <client-xid> <border-px>   — window_mode.sh starts and kills it
import sys

import cairo
import gi

gi.require_version("Gdk", "3.0")
gi.require_version("GdkX11", "3.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, GdkX11, GLib, Gtk  # noqa: E402

DASH_PX, GAP_PX = 14, 10
# Poll, not i3 events (a mouse resize sends none). Alive only while the mode is
# on, and a tick with no change is two tiny X queries — nothing else.
POLL_MS = 60


def dash_region(w, h, b):
    # Dashes half the border thick, centred in it, so the colour shows both sides.
    t = max(1, b // 2)
    o = (b - t) // 2
    rects = []
    for x in range(o, w - o, DASH_PX + GAP_PX):
        n = min(DASH_PX, w - o - x)
        rects += [(x, o, n, t), (x, h - o - t, n, t)]
    for y in range(o, h - o, DASH_PX + GAP_PX):
        n = min(DASH_PX, h - o - y)
        rects += [(o, y, t, n), (w - o - t, y, t, n)]
    return cairo.Region([cairo.RectangleInt(*r) for r in rects])


def main():
    xid, border = int(sys.argv[1]), int(sys.argv[2])
    display = GdkX11.X11Display.get_default()
    client = GdkX11.X11Window.foreign_new_for_display(display, xid)
    if client is None:
        return

    win = Gtk.Window(type=Gtk.WindowType.POPUP)  # override-redirect: i3 leaves it alone
    win.set_app_paintable(True)
    win.connect("draw", lambda _w, cr: (cr.set_source_rgb(0, 0, 0), cr.paint()))
    win.realize()
    gdk_win = win.get_window()
    # Empty input shape: clicks fall through, so the border stays a resize handle.
    gdk_win.input_shape_combine_region(cairo.Region(), 0, 0)

    last = [None]

    def tick():
        # Trapped: once the window closes, every query is a BadWindow that would
        # otherwise abort the whole process — here it just ends the overlay.
        display.error_trap_push()
        _, x, y = client.get_origin()
        _, _, w, h = client.get_geometry()
        if display.error_trap_pop():
            Gtk.main_quit()
            return False
        geo = (x - border, y - border, w + 2 * border, h + 2 * border)
        if geo != last[0]:
            last[0] = geo
            win.move(geo[0], geo[1])
            win.resize(geo[2], geo[3])
            gdk_win.shape_combine_region(dash_region(geo[2], geo[3], border), 0, 0)
            win.show()
            # i3 puts a moved floating frame back on top, which would bury us.
            gdk_win.raise_()
        return True

    tick()
    GLib.timeout_add(POLL_MS, tick)
    Gtk.main()


if __name__ == "__main__":
    main()
