"""Finds out what a book file allows, so the app can tell the reader."""

from __future__ import annotations

import json
import mmap
import os
import tempfile
import zipfile

import pymupdf

SAMPLE_PAGES = 15
MIN_TEXT = 20  # letters on a page for it to count as having text


def has_word_map(path: str) -> bool:
    """Whether nots-cook embedded a word map (see tools/cook/FORMAT.md)."""
    if os.path.getsize(path) == 0:
        return False
    with open(path, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
        return m.rfind(b"/NotsWords") >= 0


def _has_text(doc: pymupdf.Document) -> bool:
    n = doc.page_count
    step = max(1, n // SAMPLE_PAGES)
    for i in range(0, n, step):
        if sum(c.isalpha() for c in doc[i].get_text()) >= MIN_TEXT:
            return True
    return False


def inspect_pdf(path: str) -> dict:
    with pymupdf.open(path) as doc:
        if doc.needs_pass:
            raise ValueError("الملف محمي بكلمة مرور")
        pages = doc.page_count
        text = _has_text(doc)
        toc = bool(doc.get_toc(simple=True))
    exact = has_word_map(path)
    return {
        "format": "pdf",
        "pages": pages,
        "features": {
            "search": text or exact,
            "marks": text or exact,
            "copy": text or exact,
            "toc": toc or exact,
            "exact": exact,
        },
    }


def inspect_nots(path: str) -> dict:
    """A .nots package: the PDF plus writing and, maybe, linked text."""
    with zipfile.ZipFile(path) as z:
        names = set(z.namelist())
        if not {"manifest.json", "book.pdf", "ink.nots"} <= names:
            raise ValueError("ليس ملف نوتس صالحاً")
        manifest = json.loads(z.read("manifest.json").decode("utf-8"))
        if manifest.get("format") != "nots-package":
            raise ValueError("ليس ملف نوتس صالحاً")
        with tempfile.TemporaryDirectory() as tmp:
            z.extract("book.pdf", tmp)
            info = inspect_pdf(os.path.join(tmp, "book.pdf"))
        linked = "link.json" in names
    f = info["features"]
    # A linked Word text gives search, copy and a table of contents.
    info["features"] = {
        **f,
        "search": f["search"] or linked,
        "copy": f["copy"] or linked,
        "toc": f["toc"] or linked,
    }
    info["format"] = "nots"
    return info


def inspect(path: str) -> dict:
    ext = os.path.splitext(path)[1].lower()
    if ext == ".pdf":
        return inspect_pdf(path)
    if ext == ".nots":
        return inspect_nots(path)
    raise ValueError("اختر ملف PDF أو نوتس (.nots)")
