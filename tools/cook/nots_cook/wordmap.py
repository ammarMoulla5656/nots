"""The word map embedded in a cooked PDF.

Every word of the book's text, in reading order, with its box on the page.
A word is identified by its index in the whole book (0, 1, 2, ...), which
never depends on the screen, the zoom or the app: a mark or a comment made
on word 51234 in one app is word 51234 in any other app reading the same
map. See FORMAT.md for the full description.
"""

from __future__ import annotations

import datetime
import json
import os
import zlib
from dataclasses import dataclass

FORMAT = 'nots-words'
VERSION = 1
UNIT = 10  # boxes are stored in tenths of a point

# Key written into the attachment's stream dictionary so readers find the
# map with a plain byte search, without a PDF parser.
MARKER_KEY = 'NotsWords'
ATTACHMENT_NAME = 'nots-words.json'


def fingerprint(path: str) -> str:
    """The app's book id: FNV-1a over the file size, its first and its last
    megabyte (lib/library/library_store.dart: fingerprintFile)."""
    chunk = 1 << 20
    size = os.path.getsize(path)
    h = 0xcbf29ce484222325
    mask = (1 << 64) - 1

    def eat(bs: bytes):
        nonlocal h
        for b in bs:
            h = ((h ^ b) * 0x100000001b3) & mask

    eat(f'{size}|'.encode())
    with open(path, 'rb') as f:
        eat(f.read(min(chunk, size)))
        if size > chunk:
            f.seek(max(chunk, size - chunk))
            eat(f.read(chunk))
    return f'{h:016x}'


def encode_boxes(rects: list[tuple[float, float, float, float] | None]) -> list[int | None]:
    """Boxes of a page's words as one flat list: per word four integers
    (x0, y0, x1, y1 in tenths of a point), each the difference from the same
    value of the previous placed word on the page (the first counts from 0);
    null alone for a word whose place is unknown. Differences are small and
    repeat a lot, so they compress well."""
    out: list[int | None] = []
    prev = (0, 0, 0, 0)
    for r in rects:
        if r is None:
            out.append(None)
            continue
        cur = tuple(round(v * UNIT) for v in r)
        out += [c - p for c, p in zip(cur, prev)]
        prev = cur
    return out


def decode_boxes(vals: list[int | None]) -> list[tuple[float, float, float, float] | None]:
    out: list[tuple[float, float, float, float] | None] = []
    prev = [0, 0, 0, 0]
    k = 0
    while k < len(vals):
        if vals[k] is None:
            out.append(None)
            k += 1
            continue
        prev = [p + d for p, d in zip(prev, vals[k:k + 4])]
        out.append(tuple(v / UNIT for v in prev))
        k += 4
    return out


@dataclass
class MapPage:
    kind: str                     # text | image | blank | ocr
    text: str                     # paragraphs separated by '\n'
    boxes: list[tuple[float, float, float, float] | None]
    size: tuple[float, float]


def build(*, title: str, pages: list[MapPage], headings: list[dict], source_pdf: str,
          source_pdf_id: str, source_text: str | None, method: str, generator: str) -> dict:
    word_count = 0
    out_pages = []
    for p in pages:
        # Words separated by one space, paragraphs by one line break: the
        # only separators readers split on (same words as str.split()).
        text = '\n'.join(' '.join(line.split()) for line in p.text.split('\n') if line.split())
        n = len(text.split())
        assert n == len(p.boxes), (n, len(p.boxes))
        word_count += n
        out_pages.append({
            'k': p.kind,
            's': [round(p.size[0], 2), round(p.size[1], 2)],
            't': text,
            'b': encode_boxes(p.boxes),
        })
    return {
        'format': FORMAT,
        'version': VERSION,
        'generator': generator,
        'created': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
        'title': title,
        'lang': 'ar',
        'source': {'pdf': source_pdf, 'pdfId': source_pdf_id, 'text': source_text, 'method': method},
        'units': 'pt/10 deltas, top-left origin, unrotated page',
        'pageCount': len(pages),
        'wordCount': word_count,
        'pages': out_pages,
        'headings': headings,
    }


def dumps(m: dict) -> bytes:
    return json.dumps(m, ensure_ascii=False, separators=(',', ':')).encode('utf-8')


def find_in_pdf(data: bytes) -> dict | None:
    """Reads the map back from PDF bytes the way the app does: find the
    marker key, then the stream that follows it."""
    k = data.rfind(b'/' + MARKER_KEY.encode())
    if k < 0:
        return None
    start = data.rfind(b'obj', 0, k)
    s = data.find(b'stream', k)
    if start < 0 or s < 0:
        return None
    head = data[start:s]
    s += len(b'stream')
    if data[s:s + 2] == b'\r\n':
        s += 2
    elif data[s:s + 1] in (b'\n', b'\r'):
        s += 1
    import re
    m = re.search(rb'/Length\s+(\d+)(\s+\d+\s+R)?', head)
    if m and not m.group(2):
        body = data[s:s + int(m.group(1))]
    else:
        e = data.find(b'endstream', s)
        body = data[s:e].rstrip(b'\r\n')
    if b'/FlateDecode' in head:
        body = zlib.decompress(body)
    return json.loads(body.decode('utf-8'))
