"""Reads every finished volume on the home server once: size, sha256, pages,
and what it allows (search, index, exact text), for the catalogue.

The books stay at home; only these facts go into the catalogue. Results are
cached by size and modification time, so a second run reads only what changed.

    python scan_books.py [--root \\\\DESKTOP-QVASHH7\\C_Drive\\nots_batch] [--out scan.json]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed

import pymupdf

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = r"\\DESKTOP-QVASHH7\C_Drive\nots_batch"


def scan_one(path: str) -> dict:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        data = f.read()
    h.update(data)
    exact = data.rfind(b"/NotsWords") >= 0
    with pymupdf.open(stream=data, filetype="pdf") as doc:
        pages = doc.page_count
        toc = bool(doc.get_toc(simple=True))
        step = max(1, pages // 15)
        text = any(sum(c.isalpha() for c in doc[i].get_text()) >= 20 for i in range(0, pages, step))
    return {
        "size": len(data), "sha256": h.hexdigest(), "pages": pages,
        "features": {
            "search": text or exact, "marks": text or exact, "copy": text or exact,
            "toc": toc or exact, "exact": exact,
        },
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--out", default=os.path.join(HERE, "data", "scan.json"))
    ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args()

    state = json.load(open(os.path.join(a.root, "state", "state.json"), encoding="utf-8"))
    cache = {}
    if os.path.exists(a.out):
        cache = json.load(open(a.out, encoding="utf-8"))
    lock = threading.Lock()
    todo = []
    for serial, d in sorted(state["done"].items()):
        path = os.path.join(a.root, d["output"])
        try:
            st = os.stat(path)
        except OSError:
            print("missing", serial, path, file=sys.stderr)
            continue
        old = cache.get(serial)
        if old and old.get("size") == st.st_size and old.get("mtime") == int(st.st_mtime) and old.get("output") == d["output"]:
            continue
        todo.append((serial, d["output"], path, int(st.st_mtime)))
    print(f"{len(todo)} to read, {len(cache)} cached", flush=True)

    def save():
        os.makedirs(os.path.dirname(a.out), exist_ok=True)
        tmp = a.out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cache, f, ensure_ascii=False, indent=0, sort_keys=True)
        os.replace(tmp, a.out)

    done = 0
    with ThreadPoolExecutor(a.workers) as pool:
        futs = {pool.submit(scan_one, p): (s, o, p, m) for s, o, p, m in todo}
        for fut in as_completed(futs):
            serial, output, path, mtime = futs[fut]
            try:
                info = fut.result()
            except Exception as e:  # a broken file stays out of the catalogue
                print("error", serial, e, file=sys.stderr, flush=True)
                continue
            with lock:
                cache[serial] = {**info, "output": output, "mtime": mtime}
                done += 1
                if done % 25 == 0:
                    save()
                    print(f"{done}/{len(todo)}", flush=True)
    save()
    print("done", len(cache), flush=True)


if __name__ == "__main__":
    main()
