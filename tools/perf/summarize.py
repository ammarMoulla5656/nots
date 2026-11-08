"""The numbers of a speed.log: frames and slow frames per screen, and the
timed steps. Reads the last session of the log (or all with --all).

    python tools/perf/summarize.py tools/perf/runs/<run>        # a run folder
    python tools/perf/summarize.py speed.log
"""

from __future__ import annotations

import os
import re
import sys
from collections import defaultdict

LINE = re.compile(r"^\s*([\d.]+)s\s+(\d+)MB\s+(\S+)\s+(\S)\s+(.*)$")
FRAMES = re.compile(
    r"frames (\d+)\s+slow>16ms (\d+)\s+>33ms (\d+)\s+build avg ([\d.]+) max ([\d.]+)\s+raster avg ([\d.]+) max ([\d.]+)"
)


def main(path: str) -> None:
    if os.path.isdir(path):
        path = os.path.join(path, "speed.log")
    text = open(path, encoding="utf-8").read()
    if "--all" not in sys.argv:
        text = "=====" + text.split("=====")[-1]
    per = defaultdict(lambda: [0, 0, 0, 0.0, 0.0, 0.0, 0.0, 0])
    steps = defaultdict(list)
    mem = 0
    opened = "reader"  # what the reader is showing: a book or a note
    for raw in text.splitlines():
        m = LINE.match(raw)
        if not m:
            continue
        _, mb, screen, kind, rest = m.groups()
        if rest.startswith("open: book"):
            opened = "reader-book"
        elif rest.startswith("open: note"):
            opened = "reader-note"
        if screen == "reader":
            screen = opened
        mem = max(mem, int(mb))
        if kind == "▦":
            f = FRAMES.search(rest)
            if f:
                n, s16, s33 = (int(f.group(i)) for i in (1, 2, 3))
                bavg, bmax, ravg, rmax = (float(f.group(i)) for i in (4, 5, 6, 7))
                p = per[screen]
                p[0] += n
                p[1] += s16
                p[2] += s33
                p[3] += bavg * n
                p[4] = max(p[4], bmax)
                p[5] += ravg * n
                p[6] = max(p[6], rmax)
                p[7] += 1
        elif kind == "⏱" and "cover made" not in rest:
            name = re.sub(r"\s+\d+ms.*$", "", rest)
            ms = re.search(r"(\d+)ms", rest)
            if ms:
                steps[name].append(int(ms.group(1)))
    print(f"{'screen':<10}{'frames':>8}{'>16ms':>8}{'%':>6}{'>33ms':>7}{'build avg':>11}{'build max':>11}{'raster avg':>12}{'raster max':>12}")
    for screen, p in sorted(per.items()):
        n = p[0] or 1
        print(
            f"{screen:<10}{p[0]:>8}{p[1]:>8}{100 * p[1] / n:>5.1f}%{p[2]:>7}"
            f"{p[3] / n:>9.1f}ms{p[4]:>9.1f}ms{p[5] / n:>10.1f}ms{p[6]:>10.1f}ms"
        )
    print(f"\nmemory peak {mem} MB\n")
    for name, v in sorted(steps.items()):
        print(f"{name:<44} n={len(v):<3} avg {sum(v) // len(v):>6}ms  max {max(v):>6}ms")


if __name__ == "__main__":
    main(sys.argv[1])
