"""Checks a linked book against the PDF it came from.

1. Every page renders exactly as before (MuPDF on all pages, PDFium, the
   app's engine, on a sample): the cooking must not change a single pixel.
2. The text layer, as PDFium extracts it, compared with the source text,
   before and after.
3. The word map read back from the file the way the app reads it: counts,
   boxes inside their pages, and PDFium finding each word's letters inside
   its box.
"""

from __future__ import annotations

import collections
import difflib
import random
import time

import pymupdf

from . import wordmap
from .align import skeleton

FOLD = str.maketrans({'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا', 'ى': 'ي', 'ئ': 'ي', 'ؤ': 'و', 'ة': 'ه'})


def folded(s: str) -> str:
    return skeleton(s).translate(FOLD)


def _pdfium():
    try:
        import pypdfium2 as pdfium
        return pdfium
    except ImportError:
        return None


def check_pixels(src: str, out: str, dpi: int = 36, pdfium_every: int = 6) -> dict:
    a, b = pymupdf.open(src), pymupdf.open(out)
    bad = []
    for i in range(a.page_count):
        if a[i].get_pixmap(dpi=dpi).samples != b[i].get_pixmap(dpi=dpi).samples:
            bad.append(i + 1)
    res = {'pages': a.page_count, 'mupdf_identical': a.page_count - len(bad), 'mupdf_different': bad}
    pdfium = _pdfium()
    if pdfium:
        pa, pb = pdfium.PdfDocument(src), pdfium.PdfDocument(out)
        checked, badp = 0, []
        for i in range(0, len(pa), pdfium_every):
            x = pa[i].render(scale=dpi / 72).to_pil().tobytes()
            y = pb[i].render(scale=dpi / 72).to_pil().tobytes()
            checked += 1
            if x != y:
                badp.append(i + 1)
        res.update(pdfium_checked=checked, pdfium_different=badp)
    return res


def text_quality(path: str, source_pages: list[str]) -> dict:
    """How close PDFium's text of each page is to the source (folded
    letters, order-sensitive), averaged over pages that have text."""
    pdfium = _pdfium()
    if not pdfium:
        return {}
    pdf = pdfium.PdfDocument(path)
    ratios = []
    for i in range(min(len(pdf), len(source_pages))):
        want = folded(source_pages[i])
        if len(want) < 20:
            continue
        got = folded(pdf[i].get_textpage().get_text_range())
        ratios.append(difflib.SequenceMatcher(None, got, want, autojunk=False).ratio())
    ratios.sort()
    return {
        'pages': len(ratios),
        'mean': round(sum(ratios) / max(len(ratios), 1), 4),
        'median': round(ratios[len(ratios) // 2], 4) if ratios else 0,
        'below_0.9': sum(r < 0.9 for r in ratios),
    }


def check_map(out: str, sample: int = 4000, seed: int = 7) -> dict:
    data = open(out, 'rb').read()
    t0 = time.time()
    m = wordmap.find_in_pdf(data)
    read_ms = (time.time() - t0) * 1000
    if m is None:
        return {'found': False}
    doc = pymupdf.open(out)
    problems = collections.Counter()
    words = []  # (page index, word, box)
    odd = []
    total = with_box = 0
    for pi, p in enumerate(m['pages']):
        ws = p['t'].split()
        boxes = wordmap.decode_boxes(p['b'])
        if len(ws) != len(boxes):
            problems['count_mismatch'] += 1
            continue
        w, h = doc[pi].rect.width, doc[pi].rect.height
        for word, b in zip(ws, boxes):
            total += 1
            if b is None:
                continue
            with_box += 1
            if not (-1 <= b[0] < b[2] <= w + 1 and -1 <= b[1] < b[3] <= h + 1):
                problems['box_outside_page_or_empty'] += 1
                if len(odd) < 5:
                    odd.append({'page': pi + 1, 'word': word, 'box': b})
            words.append((pi, word, b))
    res = {'found': True, 'read_ms': round(read_ms, 1), 'words': total, 'with_box': with_box,
           'problems': dict(problems), 'odd_boxes': odd, 'headings': len(m.get('headings', []))}
    if total != m.get('wordCount'):
        problems['wordCount_field'] += 1
    pdfium = _pdfium()
    if pdfium and words:
        random.Random(seed).shuffle(words)
        pdf = pdfium.PdfDocument(out)
        pages = {}
        ok = 0
        tested = 0
        misses = []
        for pi, word, b in words[:sample]:
            want = folded(word)
            if not want:
                continue
            tp = pages.get(pi)
            if tp is None:
                tp = pages[pi] = pdf[pi].get_textpage()
            H = pdf[pi].get_height()
            got = folded(tp.get_text_bounded(left=b[0] + 0.3, bottom=H - b[3] + 0.3,
                                              right=b[2] - 0.3, top=H - b[1] - 0.3))
            tested += 1
            need = collections.Counter(want)
            have = collections.Counter(got)
            if all(have[c] >= n for c, n in need.items()):
                ok += 1
            elif len(misses) < 12:
                misses.append({'page': pi + 1, 'word': word, 'pdfium': got})
        res.update(boxes_tested=tested, boxes_confirmed=ok,
                   boxes_confirmed_share=round(ok / max(tested, 1), 4), box_misses=misses)
    return res
