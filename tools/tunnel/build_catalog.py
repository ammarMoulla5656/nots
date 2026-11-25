"""Builds the store's catalogue from the volumes on the home server.

Each book is the Masdar book it belongs to: title, author and category as the
Hikmah database (alhikmeh_repaired.db) has them, its cover from the Masdar
app, and its Masdar id. Each volume is numbered as Masdar numbers it (its
place among the book's parts in library.db), so the Masdar button opens the
same volume there.

The files are not uploaded: a part's file is `t/get.php?s=<serial>`, the
tunnel to the home server (site/get.php).

    python build_catalog.py            writes data/catalog.txt, data/_list.php
    python build_catalog.py --publish  also sends covers, tunnel and catalogue,
                                       and deletes the old books from the server
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sqlite3
import sys
import tempfile
from collections import defaultdict

import openpyxl

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(PROJECT, "tools", "publisher"))

from nots_publisher import catalog as cat  # noqa: E402
from nots_publisher import masdar  # noqa: E402

SHEET = os.path.join(PROJECT, "masaha_books_20261116_2116.xlsx")
HIKMAH_DB = os.path.join(PROJECT, "alhikmeh_repaired.db")
LIBRARY_DB = r"\\DESKTOP-QVASHH7\C_Drive\nots_batch\library.db"
COVERS = r"D:\01_Projects\reverse-engineering\book-search-apk\assets\flutter_assets\assets\images\covers"
MASDAR_CSV = os.path.join(PROJECT, "tools", "publisher", "data", "masdar_books.csv")
SCAN = os.path.join(HERE, "data", "scan.json")
OUT = os.path.join(HERE, "data")
PUBLISHER = "فريق مساحة حرة"

_JUNK = "\u200f\u200e\u200c\u200d\ufeff"
_ORDINALS = {"01": "1"}


def clean(s) -> str:
    return " ".join(str(s or "").strip(_JUNK + " ").replace("\u200f", "").split())


def category_names(db: sqlite3.Connection) -> dict[int, str]:
    """Hikmah's category numbers, by the names the Masdar app shows."""
    long_names = {}
    with open(MASDAR_CSV, encoding="utf-8-sig", newline="") as f:
        for row in csv.reader(f):
            if row and row[0].startswith("ID_"):
                long_names[int(row[0][3:])] = row[2]
    out = {}
    for book_id, num in db.execute("select id, category from Books"):
        if book_id in long_names:
            out.setdefault(num, masdar.category(long_names[book_id]))
    return out


def volume_label(joze, n: int) -> str:
    j = clean(joze)
    if not j:
        return f"الجزء {n}"
    if j.isdigit():
        return f"الجزء {int(j)}"
    return j


def build() -> tuple[dict, dict[str, int], dict[str, str], list[str]]:
    notes: list[str] = []
    hik = sqlite3.connect(HIKMAH_DB)
    books = {r[0]: r for r in hik.execute("select id, book_name, authorName, category, parts_count from Books")}
    cats = category_names(hik)
    # Parts of each book in Hikmah's order (its volume numbers in links).
    lib = sqlite3.connect(LIBRARY_DB)
    parts_of: dict[int, list[int]] = defaultdict(list)
    joze_of: dict[int, object] = {}
    for b, p, j in lib.execute("select bookID, partID, min(joze) from Contents group by bookID, partID order by bookID, partID"):
        parts_of[b].append(p)
        joze_of[p] = j
    for p, b, meaning in hik.execute("select id, word, meaning from MeaningLang"):
        if str(b).isdigit() and int(b) in books and p not in parts_of[int(b)]:
            parts_of[int(b)].append(p)
            parts_of[int(b)].sort()
            joze_of.setdefault(p, meaning)

    scan = json.load(open(SCAN, encoding="utf-8"))
    rows = list(openpyxl.load_workbook(SHEET, read_only=True).worksheets[0].iter_rows(values_only=True))
    head, rows = rows[0], rows[1:]
    col = {name: i for i, name in enumerate(head)}

    by_book: dict[int, list[tuple]] = defaultdict(list)
    for r in rows:
        serial = str(r[col["الرقم"]]).zfill(4)
        if serial not in scan:
            notes.append(f"{serial} {r[col['اسم الكتاب']]}: ليس بين الكتب المنجزة على السيرفر المنزلي، تُرك")
            continue
        book_id = int(r[col["معرف كتاب الحكمة"]])
        part_id = int(r[col["معرف جزء الحكمة"]])
        if book_id not in books:
            notes.append(f"{serial}: الكتاب {book_id} ليس في قاعدة الحكمة، تُرك")
            continue
        by_book[book_id].append((serial, part_id, r))

    out_books = []
    serials: dict[str, int] = {}
    covers: dict[str, str] = {}
    for book_id, vols in sorted(by_book.items(), key=lambda kv: min(v[0] for v in kv[1])):
        _, name, author, category, parts_count = books[book_id]
        order = parts_of.get(book_id, [])
        total = max(len(order), parts_count or 0, 1)
        parts = []
        used: dict[int, str] = {}
        for serial, part_id, r in sorted(vols, key=lambda v: v[1]):
            if part_id in order:
                n = order.index(part_id) + 1
                label = volume_label(joze_of.get(part_id), n)
            elif total == 1:
                n, label = 1, ""
            else:
                notes.append(f"{serial} {clean(name)}: الجزء {part_id} ليس في فهرس المصدر، تُرك")
                continue
            if n in used:
                notes.append(f"{serial} {clean(name)}: الجزء {n} مكرر مع {used[n]}، تُرك")
                continue
            used[n] = serial
            s = scan[serial]
            parts.append({
                "n": n, "label": label if total > 1 else "", "format": "pdf",
                "pages": s["pages"], "features": s["features"],
                "file": f"t/get.php?s={serial}", "size": s["size"], "sha256": s["sha256"],
            })
            serials[serial] = s["size"]
        if not parts:
            continue
        # Same label twice (منهاج الصالحين: two volumes "1"): name the work.
        seen = defaultdict(list)
        for p in parts:
            seen[p["label"]].append(p)
        for label, ps in seen.items():
            if label and len(ps) > 1:
                for p in ps:
                    serial = p["file"].rsplit("=", 1)[1]
                    work = next(clean(r[col["اسم الكتاب"]]) for s2, _, r in vols if s2 == serial)
                    p["label"] = f"{label} ({work})"
        parts.sort(key=lambda p: p["n"])
        cid = f"m{book_id}"
        cover = os.path.join(COVERS, f"{book_id}.jpg")
        if os.path.exists(cover):
            covers[cid] = cover
        else:
            notes.append(f"{clean(name)}: لا غلاف")
        out_books.append({
            "id": cid,
            "title": clean(name),
            "author": clean(author),
            "investigator": "",
            "edition": "",
            "language": "",
            "subject": cats.get(category, ""),
            "publisher": PUBLISHER,
            "masdar": str(book_id),
            "parts_count": total,
            "cover": "",
            "parts": parts,
        })
    return {"books": out_books}, serials, covers, notes


def list_php(serials: dict[str, int]) -> str:
    body = ",\n".join(f"'{s}'=>{n}" for s, n in sorted(serials.items()))
    return "<?php\n// Written by tools/tunnel/build_catalog.py: the volumes the tunnel may fetch.\nreturn [\n" + body + "\n];\n"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--publish", action="store_true")
    ap.add_argument("--keep-old", action="store_true", help="do not delete the old books")
    a = ap.parse_args()

    built, serials, covers, notes = build()
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "_list.php"), "w", encoding="utf-8", newline="\n") as f:
        f.write(list_php(serials))
    with open(os.path.join(OUT, "notes.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(notes) + "\n")
    books = built["books"]
    vols = sum(len(b["parts"]) for b in books)
    size = sum(p["size"] for b in books for p in b["parts"])
    print(f"{len(books)} books, {vols} volumes, {size / 2**30:.1f} GB at home; {len(notes)} notes")

    if not a.publish:
        preview = cat.empty()
        preview["books"] = books
        with open(os.path.join(OUT, "catalog.preview.txt"), "w", encoding="utf-8") as f:
            f.write(json.dumps(preview, ensure_ascii=False, indent=1))
        return

    from nots_publisher import publishing
    from nots_publisher.server import Account, Server

    with Server(Account.load()) as server:
        # 1. the tunnel
        server.upload_file(os.path.join(HERE, "site", "get.php"), "t/get.php")
        server.upload_file(os.path.join(OUT, "_list.php"), "t/_list.php")
        # 2. covers
        for b in books:
            src = covers.get(b["id"])
            if not src:
                continue
            data = publishing.make_cover(src)
            with tempfile.TemporaryDirectory() as tmp:
                p = os.path.join(tmp, "c.jpg")
                with open(p, "wb") as f:
                    f.write(data)
                remote = cat.cover_path(b["id"], cat.sha256_of(p))
                server.upload_file(p, remote)
            b["cover"] = remote
            print("cover", b["title"], flush=True)
        # 3. the catalogue: the new books replace every old one
        catalog = publishing.load_catalog(server)
        old = catalog["books"]
        keep_files = {f for b in books for f in cat.files_of(b)}
        catalog["books"] = []
        for b in books:
            cat.put(catalog, b)
        if a.keep_old:
            catalog["books"].extend(old)
        publishing.save_catalog(server, catalog)
        print("catalogue saved", len(catalog["books"]))
        # 4. the old books' files, now that nothing names them
        if not a.keep_old:
            for b in old:
                for path in cat.files_of(b) - keep_files:
                    if path.startswith(("books/", "covers/")):
                        server.delete(path)
                server.delete_empty_folder(f"books/{b['id']}")
                print("deleted", b["id"], b.get("title"), flush=True)


if __name__ == "__main__":
    main()
