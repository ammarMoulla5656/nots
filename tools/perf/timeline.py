"""Where the app got slow: the frames of a speed.log in windows of time, with
the memory and the screens in each, and the events (opening a book, new
note, sync) at their times. Reads the last session of the log.

    python tools/perf/timeline.py <speed.log or run folder> [window seconds]
"""

from __future__ import annotations

import collections
import os
import re
import sys

L = re.compile(r"^\s*([\d.]+)s\s+(\d+)MB\s+(\S+)\s+(\S)\s+(.*)$")
F = re.compile(
    r"frames (\d+)\s+slow>16ms (\d+)\s+>33ms (\d+)\s+build avg ([\d.]+) max ([\d.]+)\s+raster avg ([\d.]+) max ([\d.]+)"
)


def main(path: str, window: int = 60) -> None:
    if os.path.isdir(path):
        path = os.path.join(path, "speed.log")
    text = open(path, encoding="utf-8").read().split("=====")[-1]
    rows = []
    for line in text.splitlines():
        m = L.match(line)
        if m:
            rows.append((float(m[1]), int(m[2]), m[3], m[4], m[5]))
    if not rows:
        print("no lines")
        return
    print("events:")
    for s, mb, scr, k, r in rows:
        if r.startswith("open:") or "sync pass" in r or "new note" in r or "reader: open" in r:
            print(f"  {s:7.0f}s {mb:5d}MB {scr:9s} {r[:90]}")
    print(f"\n{'window':<11}{'frames':>7}{'>16ms':>7}{'%':>7}{'>33ms':>7}{'build max':>11}{'raster max':>12}{'MB':>6}  screens")
    win = collections.OrderedDict()
    for s, mb, scr, k, r in rows:
        if k != "▦":
            continue
        f = F.search(r)
        if not f:
            continue
        w = int(s // window) * window
        d = win.setdefault(w, [0, 0, 0, 0.0, 0.0, 0, set()])
        d[0] += int(f[1])
        d[1] += int(f[2])
        d[2] += int(f[3])
        d[3] = max(d[3], float(f[5]))
        d[4] = max(d[4], float(f[7]))
        d[5] = max(d[5], mb)
        d[6].add(scr)
    for w, d in win.items():
        print(
            f"{w:4d}-{w + window:<6}{d[0]:7d}{d[1]:7d}{100 * d[1] / max(d[0], 1):6.1f}%{d[2]:7d}"
            f"{d[3]:9.1f}ms{d[4]:10.1f}ms{d[5]:6d}  {','.join(sorted(d[6]))}"
        )


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 60)
