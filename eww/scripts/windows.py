#!/usr/bin/env python3
# Window counters for the bar: per output, how many windows on its visible
# workspace you can click right now, and how many there are in all.
# Shape: {"eDP-1": {"vis": 2, "all": 3}, ...}
#
# "Visible" means clickable: some part of the window, at least MIN_PX x MIN_PX,
# is not covered by a window above it. A sliver — a few pixels, a bit of border
# — does not count. The stacking order is i3's own: tiled windows at the bottom,
# then the floating ones in floating_nodes order, the last one on top. Only the
# shown tab of a tabbed or stacked container is visible, and a fullscreen
# window hides everything else on the workspace.
#
# i3 sends no event when a floating window is moved or resized (by a command or
# the mouse), so the tree is re-read every POLL_S as well as on each event, and
# a line is printed only when a number changes.
import json
import os
import select
import socket
import struct
import subprocess
import sys
import time

MIN_PX = int(os.environ.get("I3RC_VISIBLE_MIN_PX", "30"))
POLL_S = 1.0


# i3's IPC socket, spoken directly: no i3-msg process per read. Opened on first
# use and again after i3 restarts (the old socket then fails).
GET_WORKSPACES, GET_TREE = 1, 4
_sock = None


def _connect():
    path = subprocess.run(["i3", "--get-socketpath"], capture_output=True,
                          text=True).stdout.strip()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    return s


def _recv(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise OSError("i3 closed the socket")
        buf += chunk
    return buf


def i3(msg_type):
    global _sock
    try:
        if _sock is None:
            _sock = _connect()
        _sock.sendall(b"i3-ipc" + struct.pack("=II", 0, msg_type))
        n, _ = struct.unpack("=II", _recv(_sock, 14)[6:])
        return json.loads(_recv(_sock, n))
    except (OSError, ValueError):
        if _sock is not None:
            _sock.close()
        _sock = None
        return None


def leaves(con):
    """Every window under con, tiled or floating."""
    if con.get("window") is not None:
        yield con
    for c in con.get("nodes", []) + con.get("floating_nodes", []):
        yield from leaves(c)


def shown_tiled(con):
    """Tiled windows under con that are drawn: one tab per tabbed/stacked."""
    if con.get("window") is not None:
        yield con
        return
    kids = con.get("nodes", [])
    if con.get("layout") in ("tabbed", "stacked") and kids:
        top = con.get("focus", [None])[0] if con.get("focus") else None
        kids = [c for c in kids if c["id"] == top] or kids[:1]
    for c in kids:
        yield from shown_tiled(c)


def clip(r, area):
    x0, y0 = max(r["x"], area["x"]), max(r["y"], area["y"])
    x1 = min(r["x"] + r["width"], area["x"] + area["width"])
    y1 = min(r["y"] + r["height"], area["y"] + area["height"])
    return x0, y0, x1, y1


def clickable(rect, above, area):
    """True if a MIN_PX square inside rect (and the area) misses every rect above.

    Works on the square's top-left corner: it may go anywhere in the window
    shrunk by MIN_PX, and each window above blocks the corners whose square
    would touch it. If any corner is free, one is free that sits on the left
    edge or right after a blocker, and on the top edge or right below one — so
    only those few points need checking.
    """
    t = MIN_PX
    x0, y0, x1, y1 = clip(rect, area)
    if x1 - x0 < t or y1 - y0 < t:
        return False
    bl = [(b["x"] - t, b["y"] - t, b["x"] + b["width"], b["y"] + b["height"])
          for b in above]
    xs = [x0] + [b[2] for b in bl if x0 <= b[2] <= x1 - t]
    ys = [y0] + [b[3] for b in bl if y0 <= b[3] <= y1 - t]
    for cx in xs:
        for cy in ys:
            if not any(a < cx < c and b < cy < d for a, b, c, d in bl):
                return True
    return False


def count(ws):
    allw = list(leaves(ws))
    area = ws["rect"]
    fs = [w for w in allw if w.get("fullscreen_mode") == 1]
    if fs:
        return {"vis": 1, "all": len(allw)}
    # Bottom to top: (rect, window) pairs. A floating con is drawn as one frame.
    stack = [(w["rect"], w) for w in shown_tiled(ws)]
    for fc in ws.get("floating_nodes", []):
        stack.append((fc["rect"], fc))
    vis = 0
    for i, (r, _) in enumerate(stack):
        if clickable(r, [s[0] for s in stack[i + 1:]], area):
            vis += 1
    return {"vis": vis, "all": len(allw)}


def state():
    tree = i3(GET_TREE)
    wss = i3(GET_WORKSPACES)
    if tree is None or wss is None:
        return {}
    shown = {w["name"]: w["output"] for w in wss if w.get("visible")}
    out = {}
    for o in tree.get("nodes", []):
        for content in o.get("nodes", []):
            for ws in content.get("nodes", []):
                if ws.get("type") == "workspace" and shown.get(ws["name"]) == o["name"]:
                    out[o["name"]] = count(ws)
    return out


def main():
    last = None
    sub = None
    while True:
        if sub is None or sub.poll() is not None:
            sub = subprocess.Popen(
                ["i3-msg", "-t", "subscribe", "-m",
                 '["window","workspace","output"]'],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        ready, _, _ = select.select([sub.stdout], [], [], POLL_S)
        if ready:
            # Drain the burst: one switch fires several events. Nothing read
            # means i3 went away (a restart): wait, then subscribe again.
            if not os.read(sub.stdout.fileno(), 65536):
                sub.wait()
                sub = None
                time.sleep(1)
        cur = state()
        if cur != last:
            print(json.dumps(cur, separators=(",", ":")), flush=True)
            last = cur


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        sys.exit(0)
