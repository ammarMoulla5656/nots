"""Writes the linked book: the same PDF, page for page and pixel for pixel,
with a correct text layer, a table of contents and the word map.

Nothing that is drawn changes: page content streams are not touched. Only
/ToUnicode tables (which only text extraction reads), the outline, the
catalog's language and one attachment are written.
"""

from __future__ import annotations

import collections
import re

import pymupdf

from . import wordmap
from .align import Decoder, skeleton
from .fonts import PdfFont, tounicode_cmap


def final_tounicode(pf: PdfFont, dec: Decoder) -> dict[int, str]:
    """code -> text for an Identity font: learned, else the font's own
    tables, else what the PDF said."""
    out = dict(pf.tounicode)
    learned = {g for (f, g) in dec.learned if f == pf.name}
    zeros = {g for (f, g) in dec.zero_marks if f == pf.name}
    for gid in set(pf.tounicode) | set(dec.family_maps.get(pf.name, {})) | learned | zeros:
        k = (pf.name, gid)
        s = dec.learned.get(k) or dec.from_font(pf.name, gid)
        if s:
            if skeleton(out.get(gid, '')) != s:
                out[gid] = s
        elif k in dec.zero_marks:
            out[gid] = '\u064e'
    return out


def fix_text_layer(doc: pymupdf.Document, fonts: dict[int, PdfFont], dec: Decoder) -> list[dict]:
    """Rewrites the /ToUnicode of every font whose glyphs it got wrong."""
    shared = collections.Counter(pf.tounicode_xref for pf in fonts.values() if pf.tounicode_xref)
    changes = []
    for pf in fonts.values():
        if not pf.identity:
            continue  # simple fonts here only carry spaces and brackets
        new = final_tounicode(pf, dec)
        diff = sum(1 for g, s in new.items() if pf.tounicode.get(g) != s)
        if not diff:
            continue
        data = tounicode_cmap(new)
        if pf.tounicode_xref and shared[pf.tounicode_xref] == 1:
            doc.update_stream(pf.tounicode_xref, data, compress=True)
        else:
            x = doc.get_new_xref()
            doc.update_object(x, '<<>>')
            doc.update_stream(x, data, new=True, compress=True)
            doc.xref_set_key(pf.xref, 'ToUnicode', f'{x} 0 R')
        changes.append({'font': pf.name, 'xref': pf.xref, 'glyphs': len(new), 'changed': diff})
    return changes


def real_outline_entries(toc: list) -> int:
    """How many of the PDF's own bookmarks name something. Scanned books often
    carry one bookmark per scanned image ('الغدير_ج5_Page_001', ...), or bare
    numbers: those name no chapter. Titles that differ only in their digits
    are counted as such a run once there are five or more of them."""
    shapes = collections.Counter(re.sub(r'[\d\W_]+', '', t[1]) for t in toc)
    junk = sum(n for s, n in shapes.items() if not s or n >= 5)
    return len(toc) - junk


def add_outline(doc: pymupdf.Document, headings: list[dict]) -> int:
    """Bookmarks from the source headings, replacing the PDF's own outline
    only when it names fewer places (some PDFs ship with a token one- or
    two-entry outline, or one bookmark per scanned page named after the
    image file, that is not worth keeping)."""
    if not headings or real_outline_entries(doc.get_toc()) >= len(headings):
        return 0
    top = min(h['l'] for h in headings)
    toc = []
    prev = 0
    for h in headings:
        lvl = h['l'] - top + 1
        lvl = 1 if not toc else min(lvl, prev + 1)
        page = min(max(h['p'], 1), doc.page_count)
        toc.append([lvl, h['t'][:200], page])
        prev = lvl
    doc.set_toc(toc)
    return len(toc)


def embed_map(doc: pymupdf.Document, data: bytes, title: str) -> int:
    name = wordmap.ATTACHMENT_NAME
    if name in doc.embfile_names():
        doc.embfile_del(name)
    doc.embfile_add(name, data, filename=name, ufilename=name,
                    desc=f'Word map of "{title}" ({wordmap.FORMAT} v{wordmap.VERSION})')
    for x in range(doc.xref_length() - 1, 0, -1):
        if doc.xref_get_key(x, 'Type')[1] == '/EmbeddedFile':
            doc.xref_set_key(x, wordmap.MARKER_KEY, 'true')
            return x
    raise RuntimeError('attachment stream not found')


def save(doc: pymupdf.Document, path: str):
    # garbage=3 drops unused objects and merges duplicates; content streams
    # are left exactly as they are (no clean=True).
    doc.save(path, garbage=3, deflate=True, use_objstms=1)
