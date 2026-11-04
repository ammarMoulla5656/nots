"""The catalogue: one JSON text listing every published book.

The app reads it as `nots/catalog.txt`. It is `.txt` because the folder's
`.htaccess` refuses `.json` files to the web. Keep the fields in step with
`app/lib/catalog/catalog_models.dart`.
"""

from __future__ import annotations

import hashlib
import json
import secrets
import time
from datetime import datetime, timezone

FORMAT = "nots-catalog"
VERSION = 1

# Same names as the book columns of the older library database on the server.
TEXT_FIELDS = (
    "title", "author", "investigator", "edition",
    "language", "subject", "publisher",
)
FEATURES = ("search", "marks", "copy", "toc", "exact")


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def empty() -> dict:
    return {"format": FORMAT, "version": VERSION, "updated": now_iso(), "books": []}


def parse(text: str) -> dict:
    data = json.loads(text)
    if not isinstance(data, dict) or data.get("format") != FORMAT:
        raise ValueError("ليس فهرس نوتس")
    if not isinstance(data.get("books"), list):
        raise ValueError("الفهرس بلا قائمة كتب")
    return data


def dumps(catalog: dict) -> str:
    return json.dumps(catalog, ensure_ascii=False, separators=(",", ":"))


def new_book_id() -> str:
    return f"b{int(time.time()):x}{secrets.token_hex(3)}"


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def part_path(book_id: str, number: int, ext: str, digest: str) -> str:
    """Server path of a part, under `nots/`.

    The name carries the content's hash, so replacing a file never disturbs
    a download of the old one that is still running.
    """
    return f"books/{book_id}/p{number:02d}-{digest[:8]}.{ext}"


def cover_path(book_id: str, digest: str) -> str:
    return f"covers/{book_id}-{digest[:8]}.jpg"


def find(catalog: dict, book_id: str) -> dict | None:
    for b in catalog["books"]:
        if b["id"] == book_id:
            return b
    return None


def files_of(book: dict) -> set[str]:
    """Every server path a book entry refers to."""
    out = {p["file"] for p in book.get("parts", [])}
    if book.get("cover"):
        out.add(book["cover"])
    return out


def put(catalog: dict, book: dict) -> set[str]:
    """Adds or replaces [book]; returns the files no longer referenced."""
    now = now_iso()
    old = find(catalog, book["id"])
    book["updated"] = now
    if old is None:
        book.setdefault("added", now)
        catalog["books"].append(book)
        stale: set[str] = set()
    else:
        book["added"] = old.get("added", now)
        catalog["books"][catalog["books"].index(old)] = book
        stale = files_of(old) - files_of(book)
    catalog["updated"] = now
    return stale


def remove(catalog: dict, book_id: str) -> set[str]:
    """Removes a book; returns its files."""
    old = find(catalog, book_id)
    if old is None:
        return set()
    catalog["books"].remove(old)
    catalog["updated"] = now_iso()
    return files_of(old)


def values_of(catalog: dict, field: str) -> list[str]:
    """The distinct values of a field, to offer while typing."""
    return sorted({b[field] for b in catalog["books"] if b.get(field)})
