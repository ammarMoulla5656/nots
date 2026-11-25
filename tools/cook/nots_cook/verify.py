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
try:  # the same algorithm compiled: identical results, ~11x faster
    import cydifflib as difflib
except ImportError:
    import difflib
import os
import random
import time
from concurrent.futures import ProcessPoolExecutor

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


def _different_pages(src: str, out: str, first: int, last: int, dpi: int) -> list[int]:
    a, b = pymupdf.open(src), pymupdf.open(out)
    bad = []
    for i in range(first, last):
        pa = a[i].get_pixmap(dpi=dpi, colorspace=pymupdf.csGRAY, alpha=False)
        pb = b[i].get_pixmap(dpi=dpi, colorspace=pymupdf.csGRAY, alpha=False)
        if pa.samples != pb.samples:
            bad.append(i + 1)
    a.close()
    b.close()
    return bad


def check_pixels(src: str, out: str, dpi: int = 24, pdfium_every: int = 10) -> dict:
    with pymupdf.open(src) as a:
        n_pages = a.page_count
    # A scanned page is a full-size image to decode even at 24 dpi: 474 pages
    # took 70 s on one core. MuPDF is not thread-safe, so processes share them.
    procs = min(os.cpu_count() or 1, 16, max(1, n_pages // 25))
    if procs > 1:
        cuts = [n_pages * k // procs for k in range(procs + 1)]
        try:
            with ProcessPoolExecutor(procs) as ex:
                parts = ex.map(_different_pages, [src] * procs, [out] * procs,
                               cuts[:-1], cuts[1:], [dpi] * procs)
                bad = [p for part in parts for p in part]
        except Exception:  # no processes to be had: one core it is
            bad = _different_pages(src, out, 0, n_pages, dpi)
    else:
        bad = _different_pages(src, out, 0, n_pages, dpi)
    res = {'pages': n_pages,
           'mupdf_identical': n_pages - len(bad),
           'mupdf_different': bad}
    pdfium = _pdfium()
    if pdfium:
        pa, pb = pdfium.PdfDocument(src), pdfium.PdfDocument(out)
        step = max(pdfium_every, len(pa) // 40) if len(pa) > 40 else max(1, pdfium_every)
        checked, badp = 0, []
        for idx in range(0, len(pa), step):
            x = pa[idx].render(scale=dpi / 72).to_pil().tobytes()
            y = pb[idx].render(scale=dpi / 72).to_pil().tobytes()
            checked += 1
            if x != y:
                badp.append(idx + 1)
        pa.close()
        pb.close()
        res.update(pdfium_checked=checked, pdfium_different=badp)
    return res


def text_quality(path: str, source_pages: list[str], max_samples: int = 120) -> dict:
    """How close PDFium's text of each page is to the source (folded
    letters, order-sensitive), averaged over pages that have text."""
    pdfium = _pdfium()
    if not pdfium:
        return {}
    pdf = pdfium.PdfDocument(path)
    n = min(len(pdf), len(source_pages))
    step = max(1, n // max_samples) if n > max_samples else 1
    ratios = []
    for i in range(0, n, step):
        want = folded(source_pages[i])
        if len(want) < 20:
            continue
        got = folded(pdf[i].get_textpage().get_text_range())
        ratios.append(difflib.SequenceMatcher(None, got, want, autojunk=False).ratio())
    pdf.close()
    ratios.sort()
    return {
        'pages': len(ratios),
        'mean': round(sum(ratios) / max(len(ratios), 1), 4),
        'median': round(ratios[len(ratios) // 2], 4) if ratios else 0,
        'below_0.9': sum(r < 0.9 for r in ratios),
    }


def check_map(out: str, sample: int = 4000, seed: int = 7,
              text_layer_pages: set[int] = frozenset()) -> dict:
    data = open(out, 'rb').read()
    t0 = time.time()
    m = wordmap.find_in_pdf(data)
    read_ms = (time.time() - t0) * 1000
    if m is None:
        return {'found': False}
    doc = pymupdf.open(out)
    problems = collections.Counter()
    words = []       # (page index, word, box): placed by the glyphs, checkable against PDFium
    ocr_words = []   # (page index, word, box): placed by OCR, see below
    odd = []
    total = with_box = 0
    for pi, p in enumerate(m['pages']):
        ws = p['t'].split()
        boxes = wordmap.decode_boxes(p['b'])
        if len(ws) != len(boxes):
            problems['count_mismatch'] += 1
            continue
        w, h = doc[pi].rect.width, doc[pi].rect.height
        # OCR-placed words can only be checked against PDFium where this
        # tool wrote the page's text layer itself (a scan); elsewhere
        # PDFium reads the glyph layer OCR was used to work around.
        bucket = ocr_words if p.get('k') == 'ocr' and pi not in text_layer_pages else words
        for word, b in zip(ws, boxes):
            total += 1
            if b is None:
                continue
            with_box += 1
            if not (-1 <= b[0] < b[2] <= w + 1 and -1 <= b[1] < b[3] <= h + 1):
                problems['box_outside_page_or_empty'] += 1
                if len(odd) < 5:
                    odd.append({'page': pi + 1, 'word': word, 'box': b})
            bucket.append((pi, word, b))
    doc.close()
    res = {'found': True, 'read_ms': round(read_ms, 1), 'words': total, 'with_box': with_box,
           'problems': dict(problems), 'odd_boxes': odd, 'headings': len(m.get('headings', []))}
    if total != m.get('wordCount'):
        problems['wordCount_field'] += 1
    pdfium = _pdfium()
    if pdfium and words:
        # Only words the glyphs themselves placed: their box can be cross-
        # checked against what PDFium's own text extraction finds there,
        # since both read the same (fixed) glyph layer. A word OCR placed
        # has nothing to cross-check this way — the page's glyph layer is
        # exactly what OCR was used because it could not be trusted.
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
            if pi not in pages:
                # PDFium's coordinates are the PDF's own; the map's are from
                # the top left of the visible page (the CropBox), which need
                # not start at 0 (al-Mizan 6: 9.72 pt in). Without the shift
                # 4 words in 200 were "confirmed", with it 200.
                left, _, _, top = pdf[pi].get_cropbox()
                pages[pi] = (pdf[pi].get_textpage(), left, top)
            tp, x0, y1 = pages[pi]
            got = folded(tp.get_text_bounded(left=x0 + b[0] + 0.3, bottom=y1 - b[3] + 0.3,
                                              right=x0 + b[2] - 0.3, top=y1 - b[1] - 0.3))
            tested += 1
            need = collections.Counter(want)
            have = collections.Counter(got)
            if all(have[c] >= n for c, n in need.items()):
                ok += 1
            elif len(misses) < 12:
                misses.append({'page': pi + 1, 'word': word, 'pdfium': got})
        pdf.close()
        res.update(boxes_tested=tested, boxes_confirmed=ok,
                   boxes_confirmed_share=round(ok / max(tested, 1), 4), box_misses=misses)
    res['ocr_placed_words'] = len(ocr_words)
    if ocr_words:
        # These can only be checked by eye (cook.py --debug-pages draws
        # them); the per-page match each achieved while cooking is in the
        # run's own report.json, pages[].match, for pages of kind "ocr".
        res['ocr_note'] = ('boxes_confirmed_share excludes these: PDFium reads the same broken '
                           'glyph layer OCR was used to work around, so it can never confirm them.')
    return res
