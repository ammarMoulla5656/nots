"""nots-cook command line.

    python cook.py BOOK.pdf [--text BOOK.docx] [-o OUT.pdf]
    python cook.py FOLDER            # every PDF in the folder, paired with
                                     # the Word file of the same book

Writes BOOK.nots.pdf next to the book (or OUT.pdf) and BOOK.nots.report.json.
"""

from __future__ import annotations

import argparse
import collections
import difflib
import json
import os
import re
import sys
import tempfile
import threading
import time
from pathlib import Path

import pymupdf

from . import __version__, complete, engines, ocr, pagematch, textlayer, verify, wordmap, writer
from .pipeline import Analysis, analyze, log
from .source_text import DEFAULT_DROP, SourcePage, SourceText, read_source
from .align import align, fill_gaps, word_boxes


def find_source(pdf: Path) -> Path | None:
    """The Word, EPUB or text file of the same book next to the PDF: the
    only one there, or the one whose name and size best match the book."""
    cands = [p for p in pdf.parent.iterdir()
             if p.suffix.lower() in ('.docx', '.epub', '.txt') and not p.name.startswith('~$')
             and '.nots.' not in p.name]  # not this tool's own output
    if not cands:
        return None
    if len(cands) == 1:
        return cands[0]

    pdf_words = {w for w in pdf.stem.replace('_', ' ').replace('-', ' ').split() if len(w) >= 3}

    def score(p: Path) -> tuple[float, int]:
        ratio = difflib.SequenceMatcher(None, p.stem, pdf.stem).ratio()
        p_words = {w for w in p.stem.replace('_', ' ').replace('-', ' ').split() if len(w) >= 3}
        shared = len(pdf_words & p_words)
        try:
            sz = p.stat().st_size
        except Exception:
            sz = 0
        # Penalize tiny stub files (< 60 KB) when another candidate is > 200 KB
        stub_penalty = 0.85 if (sz < 60_000 and any(c.stat().st_size > 200_000 for c in cands)) else 0.0
        word_bonus = 0.35 if shared >= 2 else 0.0
        return (ratio + word_bonus - stub_penalty, sz)

    return max(cands, key=score)


def _on_page(r, size):
    """[r] as a real rectangle on the page (at least a point wide and
    high), or None when nothing of it is on the page."""
    if r is None:
        return None
    w, h = size
    x0, y0, x1, y1 = max(r[0], 0), max(r[1], 0), min(r[2], w), min(r[3], h)
    if x1 - x0 < 1:
        mid = min(max((r[0] + r[2]) / 2, 1), w - 1)
        x0, x1 = mid - 1, mid + 1
    if y1 - y0 < 1:
        return None
    return (x0, y0, x1, y1)


def heading_words(source: SourceText, finals: list[complete.FinalPage]) -> list[dict]:
    """Headings with the index of their first word in the whole book."""
    starts = []
    n = 0
    for f in finals:
        starts.append(n)
        n += len(f.words)
    out = []
    for h in source.headings:
        page = source.pages[h.page - 1]
        before = sum(len(p.split()) for p in page.paragraphs[:h.paragraph] if p)
        f = finals[h.page - 1]
        at = f.source_at[before] if before < len(f.source_at) else len(f.words)
        # A heading can hold a line break ("53\r\n السيد محمد الأقساسي": the
        # poet's number over his name); a bookmark is one line.
        out.append({'t': ' '.join(h.title.split()), 'l': h.level, 'p': h.page,
                    'w': starts[h.page - 1] + at})
    return out


def lexicon_of(source: SourceText | None) -> collections.Counter:
    """The book's vocabulary: its text's words, letters only."""
    lex: collections.Counter = collections.Counter()
    if source:
        for p in source.pages:
            for w in p.words():
                l = engines.letters(w)
                if l:
                    lex[l] += 1
    return lex


def _lookup_qari_cache(cached: dict[str, str], bp: int, rect: tuple[float, float, float, float]) -> str:
    """Finds a cached Qari reading for book page [bp] and region [rect],
    matching either the exact key or a region on the same page with >= 70%
    vertical and horizontal overlap (so regions pre-read on the GPU during
    the fast Windows pass match even if Tesseract adjusts box edges by a few
    points)."""
    x0, y0, x1, y1 = rect
    exact_key = f'{bp}:{round(x0)}:{round(y0)}:{round(x1)}:{round(y1)}'
    if exact_key in cached:
        return cached[exact_key]
    prefix = f'{bp}:'
    h = max(1.0, y1 - y0)
    w = max(1.0, x1 - x0)
    for k, val in cached.items():
        if not k.startswith(prefix):
            continue
        parts = k.split(':')
        if len(parts) != 5:
            continue
        try:
            cx0, cy0, cx1, cy1 = (float(v) for v in parts[1:])
        except ValueError:
            continue
        ov_y = min(y1, cy1) - max(y0, cy0)
        ov_x = min(x1, cx1) - max(x0, cx0)
        if ov_y >= 0.7 * min(h, max(1.0, cy1 - cy0)) and ov_x >= 0.7 * min(w, max(1.0, cx1 - cx0)):
            return val
    return ''


# Qari is for the text of the book: over half of its passages in a 2,247-page
# book were in the 10% of pages that are indexes and front matter, and passages
# of a few letters (page numbers, dots) gave it nothing to improve.
REFERENCE_TITLES = re.compile('فهرس|فهارس|المراجع|المصادر|مقدمة التحقيق')
MIN_QARI_LETTERS = 8


def reference_pages(doc: pymupdf.Document) -> set[int]:
    """The pages under the PDF's own bookmarks for indexes and front matter."""
    toc = doc.get_toc()
    pages: set[int] = set()
    for i, (level, title, page) in enumerate(toc):
        if REFERENCE_TITLES.search(title):
            end = next((t[2] for t in toc[i + 1:] if t[0] <= level), doc.page_count + 1)
            pages.update(range(page, max(end, page + 1)))
    return pages


def worth_reading(texts) -> bool:
    return sum(len(engines.letters(t)) for t in texts) >= MIN_QARI_LETTERS


def gpu_progress(reader: engines.Reader, label: str):
    """What to call as Qari reads passages: it logs how far it is and how long
    is left. The cache is tens of MB, so it is saved once a minute, not on
    every passage: a save holds up the CPU workers."""
    start = last_log = last_save = time.monotonic()

    def saved(done: int, total: int):
        nonlocal last_log, last_save
        now = time.monotonic()
        if now - last_save >= 60 or done == total:
            reader.save()
            last_save = now
        if now - last_log >= 10 or done == total:
            last_log = now
            left = (now - start) / done * (total - done) / 60
            log(f'  [GPU] strong OCR ({label}): {done}/{total} passages read, about {left:.0f} min left')

    return saved


def strong_reading(python: str, pdf_path: str, reader: engines.Reader, finish, info: dict,
                   lexicon, book_page=lambda n: n, skip=frozenset(), read_more: bool = True):
    """Qari's reading of every passage [finish] adds: it collects them
    with a dry run, reads any remaining cropped images not yet read in
    parallel on the GPU, and returns the function that puts them in."""
    doc = pymupdf.open(pdf_path)
    cached = reader.cache['qari']
    wanted: dict[str, tuple] = {}

    def key_of(page, units):
        x0, y0, x1, y1 = complete.region(units)
        return f'{book_page(page)}:{round(x0)}:{round(y0)}:{round(x1)}:{round(y1)}'

    def collect(page, words, units):
        if page in skip or not worth_reading(w for w, _ in words):
            return None
        rect = complete.region(units)
        bp = book_page(page)
        if not _lookup_qari_cache(cached, bp, rect):
            max_tok = min(700, max(64, len(words) * 6 + 40))
            wanted[key_of(page, units)] = (page, rect, max_tok)
        return None

    if read_more:
        # A dry run of the book finds the passages Qari has not read yet.
        # When it is not to read more, the dry run is a pass for nothing.
        finish(collect)
    info['passages'] = len(wanted) + len(cached)
    if wanted and read_more:
        with tempfile.TemporaryDirectory(prefix='nots_crop_', dir=str(engines.ssd_buffer_dir())) as d:
            images: dict[str, tuple[str, int]] = {}
            for n, (key, (page, (x0, y0, x1, y1), max_tok)) in enumerate(wanted.items()):
                if key in cached:
                    continue
                png = os.path.join(d, f'{n:06d}.png')
                clip = pymupdf.Rect(x0 - 6, y0 - 6, x1 + 6, y1 + 6) & doc[page - 1].rect
                doc[page - 1].get_pixmap(dpi=300, clip=clip, colorspace=pymupdf.csGRAY).save(png)
                images[key] = (png, max_tok)

            engines.qari_read(python, images, cached, gpu_progress(reader, 'Qari'), log, reader.lock)
            reader.save()
    doc.close()

    def polish(page, words, units):
        reading = _lookup_qari_cache(cached, book_page(page), complete.region(units))
        better = engines.polished(words, reading, lexicon)
        info['taken' if better else 'refused'] += 1
        return better

    return polish


CUT_SHARE = 0.55   # a page whose text holds less than this share of the letters it shows is cut short


def demote_short_pages(a: Analysis, source: SourceText, fast_got: dict, book_page, numbers: list[int],
                       has_text) -> list[int]:
    """Empties the text of the pages that [source] holds only a part of, so
    they are read from their images. A page counts when the fast engine reads
    at least 300 letters on it and the text has under CUT_SHARE of them."""
    out = []
    for n in numbers:
        pr = a.pages[n - 1]
        if not has_text(pr):
            continue
        shown = sum(len(engines.letters(w.text)) for w in fast_got.get(book_page(n), {}).get('windows') or [])
        if shown >= 300 and len(pr.src.skel) < CUT_SHARE * shown:
            source.pages[pr.number - 1] = SourcePage()
            out.append(n)
    return out


def _ranges(numbers: list[int]) -> str:
    """[1, 2, 3, 7, 9, 10] -> "1-3, 7, 9-10"."""
    out: list[str] = []
    for n in sorted(numbers):
        if out and int(out[-1].rsplit('-', 1)[-1]) == n - 1:
            out[-1] = f'{out[-1].split("-")[0]}-{n}'
        else:
            out.append(str(n))
    return ', '.join(out)


def parse_pages(text: str) -> list[int]:
    """"124,774" or "10-12,40": the page numbers, in order, each once."""
    out: set[int] = set()
    for part in text.split(','):
        first, _, last = part.strip().partition('-')
        out.update(range(int(first), int(last or first) + 1))
    return sorted(out)


def cut_source(source: SourceText, pages: list[int]) -> SourceText:
    """[source], whose pages are the PDF's, reduced to [pages]."""
    where = {n: i + 1 for i, n in enumerate(pages)}
    return SourceText(pages=[source.pages[n - 1] if n <= len(source.pages) else SourcePage() for n in pages],
                      headings=[type(h)(h.title, h.level, where[h.page], h.paragraph)
                                for h in source.headings if h.page in where],
                      name=source.name)


def pages_around(pages: list[int], count: int, reader: engines.Reader | None, lexicon, speller) -> list:
    """What the pages near [pages] hold. Headers alternate from page to
    page, and only what repeats tells a header from text, so a few pages
    cut from a book need their neighbours two and four pages away."""
    if not reader:
        return []
    near = sorted({n + d for n in pages for d in (-4, -2, 2, 4) if 1 <= n + d <= count} - set(pages))
    log(f'  reading {len(near)} neighbouring pages, only to know the running headers ...')
    return [complete.letter_page(ocr.one_reading(g, lexicon, speller))[1]
            for g in reader.read(near, fast=True).values()]


def big_picture(page: pymupdf.Page) -> bool:
    """A picture big enough to hold text of its own."""
    area = page.rect.width * page.rect.height
    return any((i['bbox'][2] - i['bbox'][0]) * (i['bbox'][3] - i['bbox'][1]) > 0.08 * area
               for i in page.get_image_info())


def debug_images(out_pdf: str, m: dict, pages: list[int], folder: Path):
    """Pages with every word's box drawn, for checking by eye."""
    doc = pymupdf.open(out_pdf)
    folder.mkdir(parents=True, exist_ok=True)
    colors = [(1, 0, 0), (0, 0.55, 0), (0, 0, 1), (0.8, 0, 0.8)]
    for pn in pages:
        if not 1 <= pn <= doc.page_count:
            continue
        page = doc[pn - 1]
        boxes = wordmap.decode_boxes(m['pages'][pn - 1]['b'])
        for k, b in enumerate(boxes):
            if b:
                page.draw_rect(pymupdf.Rect(b), color=colors[k % 4], width=0.6)
        page.get_pixmap(dpi=110).save(folder / f'page-{pn:04d}.png')
    doc.close()


def cook(pdf_path: Path, text_path: Path | None, out_path: Path, *, title: str | None,
         ocr_mode: str, check: bool, debug_pages: list[int], drop: list[str],
         strong: str = 'auto', pages: list[int] | None = None, all_pages: bool = False) -> dict:
    t0 = time.time()
    log(f'\n== {pdf_path.name}')
    source = None
    if text_path:
        source = read_source(text_path, drop)
        log(f'  text: {text_path.name}: {len(source.pages)} pages, '
            f'{sum(len(p.words()) for p in source.pages):,} words, {len(source.headings)} headings')
    doc = pymupdf.open(pdf_path)
    pdf_id = wordmap.fingerprint(str(pdf_path))
    reader = None
    if ocr_mode != 'off':
        reader = engines.Reader(str(pdf_path.resolve()), ocr.tessdata(),
                                str(pdf_path.with_name(pdf_path.stem + '.nots.ocr.json') if pages
                                    else out_path.with_name(out_path.stem + '.ocr.json')),
                                pdf_id, workers=ocr.WORKERS, log=log)
        if reader.usable:
            log(f'  OCR engines on this machine: {reader.describe()}')
        else:
            log('  no OCR on this machine: pages drawn as pictures stay without text')
            reader = None
    # Equal page counts do not mean the pages line up: a Hikmah text indexes
    # its pages by the printed number, and a 17-page volume with 17 text pages
    # had the scan shifted by 4 (placed 0%, with the EPUB 99.75%). So the
    # offset is looked for whenever there is a text and an OCR to read with
    # (about 3 s a book), and equal counts are trusted only if it finds none.
    aligned = None
    if source and reader:
        same = len(source.pages) == doc.page_count
        if not same:
            log(f'  the text has {len(source.pages)} pages and the PDF {doc.page_count}: '
                f'finding where the text\'s pages sit in the PDF ...')
        # One offset for the whole book, when 9 samples in 10 agree on it (at 7 in 10 a volume
        # of al-Bihar was accepted at +5 with its last third, pages 249-344, placed 0%).
        offset = pagematch.detect_offset(doc, source, reader, min_share=0.9, log=log if not same else None)
        if offset is None:
            # No single offset: a scan with pages inserted or missing here and there drifts
            # against the text's numbering (al-Mustadrak 8: +3 at page 40, +8 at page 450),
            # and read page for page it puts every word in the wrong place (placed 0%).
            # Each page is then matched by its content.
            aligned = pagematch.align_pages(doc, source, reader, log=log)
            if aligned:
                source, found = aligned
                log(f'  the text\'s pages drift against the PDF\'s (offset {found["offset_first"]:+d} at the start, '
                    f'{found["offset_last"]:+d} at the end): {found["matched"]} of {found["read"]} pages matched '
                    f'by their content, {found["source_pages_left_out"]} text pages left out')
            else:
                offset = pagematch.detect_offset(doc, source, reader, min_share=0.4)   # the older, looser rule
                if offset is None and not os.environ.get('NOTS_ALLOW_MISMATCH'):
                    # Another edition, or another volume: reading it all would take
                    # 40 minutes for 0-5% of the words placed.
                    raise RuntimeError('MISMATCH: this text does not match this PDF (too few pages of the PDF '
                                       'find their page in the text, at any offset)')
                if offset is None:
                    log('  WARNING: could not place the text\'s pages in the PDF with confidence; '
                        'matching by page number instead — check the result.')
        if offset is not None and not (same and offset == 0):
            if same:
                log(f'  the text and the PDF have {doc.page_count} pages each, but the text\'s pages '
                    f'sit {offset:+d} in the PDF: shifted')
            source = pagematch.apply_offset(doc, source, offset)
        if offset is not None or aligned:
            covered = [i for i, p in enumerate(source.pages) if p.words()]
            if covered and not (same and offset == 0 and not aligned):
                log(f'  matched: the text covers PDF pages {covered[0] + 1}-{covered[-1] + 1} '
                    f'of {doc.page_count}')
            elif not covered:
                log('  matched, but no page lined up with confidence')
    # Only some pages: they come out as they would from the whole book, with
    # the book's vocabulary and phrases, and its headers known for what they are.
    lexicon = lexicon_of(source)
    phrases = complete.phrase_table([p.text for p in source.pages]) if source else {}
    speller = engines.Speller(w for p in source.pages for w in p.words()) if source else None
    around: list = []
    book_page = lambda n: n
    book_title = (doc.metadata or {}).get('title') or pdf_path.stem
    reference = reference_pages(doc)
    cut_path = None
    if pages:
        wrong = [n for n in pages if not 1 <= n <= doc.page_count]
        if wrong:
            raise ValueError(f'the PDF has {doc.page_count} pages, not {wrong}')
        around = pages_around(pages, doc.page_count, reader, lexicon, speller)
        cut = pymupdf.open()
        for n in pages:
            cut.insert_pdf(doc, from_page=n - 1, to_page=n - 1)
        cut_path = out_path.with_name(out_path.stem + '.original.pdf')
        cut.save(cut_path, garbage=3, deflate=True)
        cut.close()
        doc.close()
        doc = pymupdf.open(cut_path)
        pdf_path = cut_path
        pdf_id = wordmap.fingerprint(str(cut_path))
        source = cut_source(source, pages) if source else None
        book_page = lambda n: pages[n - 1]
        log(f'  only pages {pages} of the book')
    a: Analysis = analyze(doc, source)

    def has_text(pr) -> bool:
        return bool(source and pr.number <= len(source.pages) and source.pages[pr.number - 1].words())

    # What each page's PDF side holds, as far as its glyphs tell.
    compare: dict[int, tuple] = {}   # page -> (units, letters on the PDF side, alignment, source)
    units_of: dict[int, list] = {}
    for pr in a.pages:
        if pr.glyphs and pr.decoded:
            units_of[pr.number] = complete.glyph_units(pr.decoded)
            if pr.alignment is not None:
                compare[pr.number] = (units_of[pr.number], pr.decoded.skel, pr.alignment, pr.src)
    height = doc[0].rect.height
    repeated = complete.edge_words(list(units_of.values()) + around, height)

    # OCR reads what the glyphs cannot give: pages drawn as pictures, pages
    # whose font could not be decoded, big pictures on a text page, and
    # passages the text lacks where the glyphs are not to be trusted.
    weak = 0.75

    # With a text, the pages before its first page and after its last (front
    # matter, the printed index, extra pages) are left as they are: no OCR, no
    # text. The index is in the bookmarks, and only the book's text belongs in
    # the copy. A page the text leaves empty between them is read as before:
    # its text is most often on the page before (an EPUB that merged two
    # pages: al-Mizan 6 had 85 such pages).
    covered = [pr.number for pr in a.pages if has_text(pr)]
    skip_uncovered = bool(source) and bool(covered) and not all_pages
    uncovered = [pr.number for pr in a.pages
                 if skip_uncovered and not covered[0] <= pr.number <= covered[-1]]
    left_alone = set(uncovered)
    if uncovered:
        log(f'  {len(uncovered)} pages before and after the text (front matter, index): '
            f'left without text ({_ranges(uncovered)})')

    def needs_ocr(pr) -> bool:
        if pr.number in left_alone:
            return False
        if ocr_mode == 'force':
            return True
        if not pr.glyphs:
            return pr.images > 0
        if not has_text(pr):
            return bool(lexicon) and complete.known_share(units_of.get(pr.number, []), lexicon) < 0.6
        if pr.ratio < weak or big_picture(doc[pr.number - 1]):
            return True
        if pr.number in compare:
            units, skel, al, src = compare[pr.number]
            furniture = complete.furniture_lines(units, repeated, height)
            return any(complete.known_share(g.units, lexicon) < 0.6
                       for g in complete.gaps(units, al, skel, src, furniture))
        return False

    qari = engines.find_qari() if reader and strong != 'off' else None
    qari_python = qari_device = None
    if qari:
        qari_python, qari_device = qari.rsplit('|', 1)
    use_qari = bool(qari_python and (qari_device == 'gpu' or strong == 'on'))
    # Without a source the PDF is all there is, and every page is the book.
    no_qari = {pr.number for pr in a.pages
               if source and (book_page(pr.number) in reference or not has_text(pr))}
    if use_qari and no_qari:
        log(f'  strong OCR: {len(no_qari)} pages left out (indexes, front matter, pages not in the text file)')

    numbers = [pr.number for pr in a.pages if needs_ocr(pr)] if reader else []
    ocr_info = {'engines': reader.describe() if reader else None, 'pages': len(numbers)}
    if numbers and use_qari and qari_device == 'gpu':
        # Loading Qari takes up to two minutes while the CPU reads: begun now,
        # it is ready when the first passages are, and it serves them all.
        engines.start_qari_server(qari_python, log)
    if numbers:
        log(f'  reading {len(numbers)} pages with OCR (CPU + GPU parallel pipeline) ...')
        # 1. Fast Windows OCR pass (~0.05s/page) to map page layout and discover
        #    gap/footnote regions immediately so GPU (Qari-VL) and CPU (Tesseract)
        #    can run simultaneously at 100% utilization.
        short: list[int] = []
        if reader.win_lang:
            fast_got = reader.read([book_page(n) for n in numbers], fast=True)
            if source:
                # A text cut short (the Hikmah database keeps only the first part of a long
                # page: 100% of al-A'yan's pages) holds a share of what each page shows, and
                # the rest would be read passage by passage, 40 minutes for a volume and
                # 70% of it from OCR anyway: a page like that is read whole from its image.
                short = demote_short_pages(a, source, fast_got, book_page, numbers, has_text)
                if short:
                    log(f'  {len(short)} pages whose text is cut short (it holds under {CUT_SHARE:.0%} of what the page '
                        f'shows): read from the page itself, the text\'s headings kept')
        else:
            fast_got = {}

        # Tesseract on every page (NOTS_TESS_ALL=1), not only where Windows'
        # reading falls short, was tried with the fast model: 60-95 s more a
        # book, the OCR's own match 0.5-3 points up, and the text layer of
        # al-Ghadir down from 97.8% to 96.4% (more doubtful passages added).
        tess_all = os.environ.get('NOTS_TESS_ALL') == '1'
        fast_cands = [n for n in numbers
                      if ocr_mode == 'auto' and reader.win_lang and reader.tess and not tess_all
                      and has_text(a.pages[n - 1]) and book_page(n) not in reader.cache['tesseract']]
        full_cands = [n for n in numbers if n not in fast_cands]
        if short and os.environ.get('NOTS_SHORT_PAGES', 'windows') == 'windows':
            # The speed of a volume whose text is cut short is Tesseract's (3 s a page against
            # 0.1 for Windows' OCR): its pages are read with Windows' OCR alone, 94% of the letters
            # against 97-98% for both engines merged. NOTS_SHORT_PAGES=both keeps both.
            left_to_windows = set(short)
            full_cands = [n for n in full_cands if n not in left_to_windows]
            log(f'  these {len(short)} pages are read with the Windows OCR alone (NOTS_SHORT_PAGES=both for both engines)')
        strips_needed: dict[int, tuple[float, float]] = {}
        gpu_pre_wanted: dict[str, tuple[int, tuple[float, float, float, float], int]] = {}

        if fast_got:
            # Each page's fast reading once: it served the running headers
            # and then was made again for the page itself (a third of the
            # time of the analysis, 373 pages of al-Mizan: 1,175 readings).
            first = {n: complete.letter_page(ocr.one_reading(fast_got[book_page(n)], lexicon, speller))
                     for n in numbers if book_page(n) in fast_got}
            temp_units = [units for _, units in first.values()]
            fast_rep = complete.edge_words(list(units_of.values()) + around + temp_units, height)
            for n in numbers:
                pr = a.pages[n - 1]
                bp = book_page(n)
                if n in first:
                    dec, units = first[n]
                else:
                    dec, units = complete.letter_page(ocr.one_reading({}, lexicon, speller))
                furn = complete.furniture_lines(units, fast_rep, height)
                if has_text(pr):
                    al = align(dec, pr.src)
                    ratio = al.ratio(len(dec.skel), len(pr.src.skel))
                    if ratio < 0.85:
                        w_words2 = ocr.one_reading(fast_got.get(bp, {}), lexicon, speller, columns=False)
                        dec2, units2 = complete.letter_page(w_words2)
                        al2 = align(dec2, pr.src)
                        ratio2 = al2.ratio(len(dec2.skel), len(pr.src.skel))
                        if ratio2 > ratio:
                            dec, units, al, ratio = dec2, units2, al2, ratio2
                    found = complete.gaps(units, al, dec.skel, pr.src, furn)
                    if n in fast_cands:
                        if ratio < 0.85:
                            full_cands.append(n)
                        elif found:
                            y0 = min(u.box[1] for g in found for u in g.units)
                            y1 = max(u.box[3] for g in found for u in g.units)
                            if (y1 - y0) > 0.65 * height:
                                full_cands.append(n)
                            else:
                                strips_needed[bp] = (y0, y1)
                    if use_qari and found and n not in no_qari:
                        for g in found:
                            # Only what the book will take: a gap the engines
                            # do not read as words is dropped later, and Qari
                            # would read it for nothing (al-Mizan 6 with its
                            # Hikmah text: 128 passages read, 131 words added).
                            if not worth_reading(u.text for u in g.units) \
                                    or not complete.believable(g.units, lexicon):
                                continue
                            rect = complete.region(g.units)
                            if not _lookup_qari_cache(reader.cache['qari'], bp, rect):
                                w_cnt = sum(len(u.text.split()) for u in g.units)
                                max_tok = min(700, max(64, w_cnt * 6 + 40))
                                key = f'{bp}:{round(rect[0])}:{round(rect[1])}:{round(rect[2])}:{round(rect[3])}'
                                gpu_pre_wanted[key] = (n, rect, max_tok)
                elif use_qari and n not in no_qari and units and len(numbers) <= 60 and len(gpu_pre_wanted) < 500:
                    # Uncovered page on a small/medium run: queue its text lines for parallel GPU Qari reading
                    for line in complete._lines(units):
                        if line[0].line in furn:
                            continue
                        rect = complete.region(line)
                        if not _lookup_qari_cache(reader.cache['qari'], bp, rect):
                            w_cnt = sum(len(u.text.split()) for u in line)
                            max_tok = min(400, max(48, w_cnt * 6 + 32))
                            key = f'{bp}:{round(rect[0])}:{round(rect[1])}:{round(rect[2])}:{round(rect[3])}'
                            gpu_pre_wanted[key] = (n, rect, max_tok)

        # Launch GPU (Qari-VL on CUDA) in a background thread AT THE SAME TIME
        # as CPU (Tesseract across all CPU cores) so both GPU and CPU hit 100%!
        gpu_thread = None
        if not (use_qari and gpu_pre_wanted):
            engines.stop_qari_server()      # nothing for Qari to read: its model need not be loaded
        if use_qari and gpu_pre_wanted:
            pdf_path_str = str(pdf_path.resolve())

            def run_gpu_parallel():
                try:
                    read_on_gpu()
                except Exception as e:  # the book goes on with what the CPU reads
                    log(f'  [GPU Qari] WARNING: stopped: {e!r}')

            def read_on_gpu():
                with tempfile.TemporaryDirectory(prefix='nots_par_gpu_', dir=str(engines.ssd_buffer_dir())) as g_tmp:
                    g_doc = pymupdf.open(pdf_path_str)
                    gpu_images: dict[str, tuple[str, int]] = {}
                    for idx, (key, (page_n, (x0, y0, x1, y1), max_tok)) in enumerate(gpu_pre_wanted.items()):
                        png = os.path.join(g_tmp, f'{idx:06d}.png')
                        clip = pymupdf.Rect(x0 - 6, y0 - 6, x1 + 6, y1 + 6) & g_doc[page_n - 1].rect
                        g_doc[page_n - 1].get_pixmap(dpi=300, clip=clip, colorspace=pymupdf.csGRAY).save(png)
                        gpu_images[key] = (png, max_tok)
                    g_doc.close()

                    engines.qari_read(qari_python, gpu_images, reader.cache['qari'],
                                      gpu_progress(reader, f'Qari on {qari_device.upper()}'), log, reader.lock)
                    reader.save()

            log(f'  [GPU] launching Qari ({qari_device.upper()}) on {len(gpu_pre_wanted)} passages in parallel with CPU OCR ...')
            gpu_thread = threading.Thread(target=run_gpu_parallel, daemon=True)
            gpu_thread.start()

        # Run CPU OCR (Tesseract full pages + strips) across all CPU workers simultaneously
        if full_cands:
            reader.read([book_page(n) for n in full_cands], fast=False)
        strip_got = reader.read_strips(strips_needed) if strips_needed else {}

        # What follows only merges the CPU engines' readings: it runs while
        # Qari still reads, and the GPU thread is waited for at the end.
        read = {
            book_page(n): {
                e: [engines.OcrWord.unpack(v) for v in reader.cache[e][book_page(n)]]
                for e in ('tesseract', 'windows', 'mupdf')
                if book_page(n) in reader.cache[e]
            }
            for n in numbers
        }
        for bp, sw in strip_got.items():
            if 'tesseract' not in read.get(bp, {}):
                read[bp]['tesseract'] = sw

        readings = {n: ocr.one_reading(read[book_page(n)], lexicon, speller) for n in numbers}
        for words in readings.values():  # what two engines agree on is a word of the book
            for w in words:
                l = engines.letters(w.text)
                if w.both and len(l) > 1:
                    lexicon[l] += 1
        floor = 0.45
        rough_pages = 0
        for n in numbers:
            pr = a.pages[n - 1]
            dec, units = complete.letter_page(readings[n])
            if not has_text(pr):
                units_of[n] = units
                if pr.glyphs:
                    pr.kind = 'ocr'
                continue
            al = align(dec, pr.src)
            ratio = al.ratio(len(dec.skel), len(pr.src.skel))
            if ratio < 0.85:
                # What looked like two columns may be the halves of verses.
                across = ocr.one_reading(read[book_page(n)], lexicon, speller, columns=False)
                dec2, units2 = complete.letter_page(across)
                if dec2.skel != dec.skel:
                    al2 = align(dec2, pr.src)
                    ratio2 = al2.ratio(len(dec2.skel), len(pr.src.skel))
                    if ratio2 > ratio:
                        dec, units, al, ratio = dec2, units2, al2, ratio2
            # A text cut short (the repaired Hikmah database keeps only the
            # first part of a long page: al-Mizan 6, page 13, 561 of 2,976
            # letters) matches a small part of the page and its ratio stays
            # low, though the page holds all of it. Most of its letters found
            # in order on the page: it is this page's text, and what it lacks
            # is added from the page like any passage the text does not have.
            src_len = len(pr.src.skel)
            partial = src_len >= 40 and al.matched >= 0.8 * src_len
            if ratio >= floor or partial:
                compare[n] = (units, dec.skel, al, pr.src)
                units_of[n] = units
                if ratio > pr.ratio:
                    pr.boxes = word_boxes(dec, pr.src, al)
                    pr.kind = 'ocr'
                    pr.ratio = ratio
            elif ratio >= complete.ROUGH_FLOOR and units and pr.src.words and ratio > pr.ratio:
                # The page is this page (reading and text share 33-45% of their letters, where
                # unrelated pages share under 30%) but the reading is too rough to pin each
                # word: the words go on the lines by letters. 18% of al-Mu'jam's pages.
                units_of[n] = units
                pr.boxes = complete.rough_boxes(units, pr.src)
                pr.kind = 'ocr'
                pr.ratio = ratio
                rough_pages += 1
        if rough_pages:
            log(f'  {rough_pages} pages whose reading is too rough to place each word (numbered references): '
                f'the words are spread along the lines by letters')
        repeated = complete.edge_words(list(units_of.values()) + around, height)
        if gpu_thread is not None:
            if strong != 'on':
                # The CPU is done: the book takes what Qari has read by now
                # and does not wait for the rest (--strong on waits).
                read_by_now = sum(1 for k in gpu_pre_wanted if k in reader.cache['qari'])
                engines.cancel_qari()
                log(f'  [GPU] Qari read {read_by_now}/{len(gpu_pre_wanted)} passages while the CPU '
                    f'worked; the rest keep the CPU reading (--strong on waits for all)')
            gpu_thread.join()

    def finish(polish=None):
        # Each page's final words: the source's, plus what only the PDF has.
        finals: list[complete.FinalPage] = []
        added_log: list[tuple[int, str]] = []
        unread: dict[int, int] = {}  # page -> letters that did not read as text
        for i, pr in enumerate(a.pages):
            size = (doc[i].rect.width, doc[i].rect.height)
            units = units_of.get(pr.number, [])
            furniture = complete.furniture_lines(units, repeated, height)
            body = [u for u in units if u.line not in furniture]
            if has_text(pr):
                text = source.pages[i].text
                boxes = [b.rect for b in pr.boxes] if pr.boxes else [None] * len(text.split())
                if pr.boxes:
                    # Words the alignment could not pin down still get a place
                    # between (or after) their placed neighbours: without one
                    # they would be missing from the page's text layer, and a
                    # copy would skip them.
                    boxes = [_on_page(r, size) for r in fill_gaps(text.split(), boxes)]
                f = complete.source_page(text, boxes)
                if pr.number in compare:
                    cu, skel, al, src = compare[pr.number]
                    found = complete.gaps(cu, al, skel, src, complete.furniture_lines(cu, repeated, height))
                    good = []
                    for g in found:
                        ok = (complete.known_share(g.units, lexicon) >= 0.6 if g.units[0].origin == 'glyph'
                              else complete.believable(g.units, lexicon))
                        if ok:
                            good.append(g)
                        else:
                            unread[pr.number] = unread.get(pr.number, 0) + sum(
                                len(engines.letters(u.text)) for u in g.units)
                    page_polish = polish and (lambda w, u, n=pr.number: polish(n, w, u))
                    for t in complete.insert(f, good, phrases, page_polish):
                        added_log.append((pr.number, t))
            elif pr.number in left_alone:
                f = complete.FinalPage()
            else:
                f = complete.page_from_pdf(units, furniture, lexicon, phrases,
                                           trusted=bool(units) and units[0].origin == 'glyph',
                                           polish=polish and (lambda w, u, n=pr.number: polish(n, w, u)))
                f.boxes = [_on_page(b, size) for b in f.boxes]
                kept = sum(len(engines.letters(w)) for w in f.words)
                lost = sum(len(engines.letters(u.text)) for u in body) - kept
                if lost > 0:
                    unread[pr.number] = lost
                if f.words:
                    added_log.append((pr.number, f.text))
            finals.append(f)
        return finals, added_log, unread

    # Finalize strong reading (uses the passages already read in parallel on
    # the GPU, plus any newly uncovered gap regions).
    polish_info = {'available': bool(qari), 'passages': 0, 'taken': 0, 'refused': 0}
    polish = None
    if qari:
        if use_qari:
            log(f'  strong OCR: applying Qari ({qari_device.upper()}) readings to added passages ...')
            polish = strong_reading(qari_python, str(pdf_path.resolve()), reader, finish, polish_info,
                                    lexicon, book_page, no_qari, read_more=strong == 'on')
        else:
            log('  strong OCR: Qari is on this machine, but without a GPU it takes minutes per '
                'passage: not used (--strong on uses it anyway)')
    engines.stop_qari_server()  # frees the card for the next book
    finals, added_log, unread = finish(polish)

    map_pages = []
    method = '+'.join(x for x in ('fonts', 'text' if source else '', 'ocr' if numbers else '') if x)
    for i, (pr, f) in enumerate(zip(a.pages, finals)):
        size = (doc[i].rect.width, doc[i].rect.height)
        if not f.words:
            kind = 'image' if pr.images and (pr.glyphs or units_of.get(pr.number)) else 'blank'
        elif not pr.glyphs or pr.kind == 'ocr':
            kind = 'ocr'
        else:
            kind = pr.kind
        map_pages.append(wordmap.MapPage(kind, f.text, f.boxes, size, f.added_ranges()))

    title = title or book_title
    headings = heading_words(source, finals) if source else []
    m = wordmap.build(title=title, pages=map_pages, headings=headings,
                      source_pdf=pdf_path.name, source_pdf_id=pdf_id,
                      source_text=text_path.name if text_path else None, method=method,
                      generator=f'nots-cook {__version__}')
    data = wordmap.dumps(m)

    font_changes = writer.fix_text_layer(doc, a.fonts, a.decoder)
    # A page that is only a picture (a scan) has nothing to select or copy:
    # give it the book's text as an invisible layer, word by word on the
    # boxes just found, so selecting, copying and searching work there in
    # the app and in any PDF viewer, and the page still looks the same.
    layer: dict[int, list] = {}
    for i, (f, pr) in enumerate(zip(finals, a.pages)):
        if not pr.glyphs:
            words = list(zip(f.words, f.boxes))
        else:
            # On a page with glyphs, only added words where no glyph is
            # (a picture's text): the rest is already selectable.
            ink = [g.bbox for g in pr.glyphs]
            words = [(w, b) for w, b, new in zip(f.words, f.boxes, f.added)
                     if new and b and not any(min(b[2], g[2]) > max(b[0], g[0])
                                              and min(b[3], g[3]) > max(b[1], g[1]) for g in ink)]
        if any(b for _, b in words):
            layer[i] = words
    layer_pages = textlayer.add_text_layer(doc, layer)
    if layer_pages:
        log(f'  invisible text layer written on {len(layer_pages)} pages that had no text')
    toc = writer.add_outline(doc, headings)
    doc.xref_set_key(doc.pdf_catalog(), 'Lang', '(ar)')
    writer.embed_map(doc, data, title)
    tmp = out_path.with_name(out_path.name + '.part')
    writer.save(doc, str(tmp))
    doc.close()
    os.replace(tmp, out_path)

    in_size, out_size = pdf_path.stat().st_size, out_path.stat().st_size
    words = sum(len(p.text.split()) for p in map_pages)
    placed = sum(1 for p in map_pages for b in p.boxes if b)
    log(f'  written {out_path.name}: {out_size / 1e6:.2f} MB (was {in_size / 1e6:.2f} MB), '
        f'word map {len(data) / 1e6:.2f} MB before compression')
    log(f'  {words:,} words, {placed:,} placed on their page ({placed / max(words, 1):.2%}), '
        f'{len(font_changes)} fonts given a correct text layer, {toc} bookmarks')

    added_words = sum(sum(f.added) for f in finals)
    if added_words:
        review = out_path.with_name(out_path.stem + '.added.txt')
        with open(review, 'w', encoding='utf-8') as fh:
            fh.write('ما أُضيف من PDF ولم يكن في ملف النص (للمراجعة)\n')
            for number, t in added_log:
                fh.write(f'\n=== صفحة {book_page(number)} ===\n{t}\n')
        log(f'  added from the PDF: {added_words:,} words in {len(added_log)} passages '
            f'(listed in {review.name})')
    unread_letters = sum(unread.values())
    empty = [pr.number for pr, f in zip(a.pages, finals)
             if not f.words and (pr.images or pr.glyphs) and pr.number not in left_alone]
    log(f'  every page has its text, but: {len(empty)} pages hold no readable text (photos, ornaments)'
        + (f': {empty[:12]}' if empty else '')
        + (f'; {unread_letters:,} letters on {len(unread)} pages did not read as text and were left out'
           if unread_letters else ''))

    report = {
        'tool': f'nots-cook {__version__}',
        'input': {'pdf': str(pdf_path), 'text': str(text_path) if text_path else None,
                  'pages': len(a.pages), 'bytes': in_size},
        'output': {'pdf': str(out_path), 'bytes': out_size, 'map_bytes_raw': len(data)},
        'words': words, 'placed': placed, 'bookmarks': toc,
        'learned_glyphs': len(a.decoder.learned),
        'learned': {f'{k[0]}#{k[1]}': v for k, v in sorted(a.decoder.learned.items())},
        'fonts_fixed': font_changes,
        'text_layer_pages': len(layer_pages),
        'complete': {'added_passages': len(added_log),
                     'added_words': added_words,
                     'pages_without_text': empty,
                     'unread_letters': unread,},
        'ocr': {**ocr_info, 'qari': polish_info},
        'book_pages': pages,
        'pages': [{
            'page': book_page(pr.number), 'kind': map_pages[i].kind, 'match': round(pr.ratio, 4),
            'words': len(map_pages[i].boxes),
            'placed': sum(1 for b in map_pages[i].boxes if b),
            'added': sum(finals[i].added),
            'exact': round(sum(b.exact for b in pr.boxes) / len(pr.boxes), 4) if pr.boxes else None,
        } for i, pr in enumerate(a.pages)],
    }
    text_pages_meta = [p for p in report['pages'] if p['words'] > 0 and p['match'] > 0]
    mean_page_match = (sum(p['match'] for p in text_pages_meta) / len(text_pages_meta)) if text_pages_meta else 0.0
    exact_vals = [p['exact'] for p in report['pages'] if p.get('exact') is not None]
    mean_exact_match = (sum(exact_vals) / len(exact_vals)) if exact_vals else 0.0
    placed_share = placed / max(words, 1)
    source_words_count = max(0, words - added_words)

    if check:
        log('  checking ...')
        px = verify.check_pixels(str(pdf_path), str(out_path))
        log(f'  pixels: {px["mupdf_identical"]}/{px["pages"]} pages identical (MuPDF)'
            + (f', PDFium sample {px["pdfium_checked"] - len(px["pdfium_different"])}/{px["pdfium_checked"]} identical'
               if 'pdfium_checked' in px else ''))
        report['check_pixels'] = px
        if source:
            texts = [p.text for p in map_pages]
            before, after = verify.text_quality(str(pdf_path), texts), verify.text_quality(str(out_path), texts)
            if before:
                log(f'  text layer (PDFium, native reading — unaffected by OCR placement) '
                    f'vs the source: {before["mean"]:.1%} before, {after["mean"]:.1%} after')
            report['text_layer'] = {'before': before, 'after': after}
        mc = verify.check_map(str(out_path), text_layer_pages=set(layer_pages))
        report['check_map'] = mc
        if mc.get('found'):
            log(f'  word map: read back in {mc["read_ms"]} ms, {mc["words"]:,} words, '
                f'problems: {mc["problems"] or "none"}'
                + (f', boxes confirmed by PDFium: {mc["boxes_confirmed_share"]:.2%} of {mc["boxes_tested"]}'
                   if 'boxes_tested' in mc else '')
                + (f' ({mc["ocr_placed_words"]:,} OCR-placed words excluded from that check — see pages[].match)'
                   if mc.get('ocr_placed_words') else ''))
        else:
            log('  ERROR: word map not found in the output')

    report['match_summary'] = {
        'placed_share': round(placed_share, 4),
        'mean_page_match': round(mean_page_match, 4),
        'mean_exact_match': round(mean_exact_match, 4),
        'source_words': source_words_count,
        'added_words': added_words,
        'added_passages': len(added_log),
        'unplaced_words': max(0, words - placed),
    }

    if debug_pages:
        folder = out_path.with_name(out_path.stem + '.debug')
        debug_images(str(out_path), m, debug_pages, folder)
        log(f'  debug pages in {folder}')
    if cut_path:
        cut_path.unlink(missing_ok=True)
    report['seconds'] = round(time.time() - t0, 1)
    rp = out_path.with_name(out_path.stem + '.report.json')
    rp.write_text(json.dumps(report, ensure_ascii=False, indent=1), 'utf-8')

    log('  ============================================================')
    log('  📊 ملخص نسب التطابق في الكلام ومعلومات المطابقة:')
    log(f'  • نسبة موضعة الكلمات بالصفحات : {placed_share:.2%} ({placed:,} من {words:,} كلمة | غير موضعة: {words - placed:,})')
    if text_pages_meta:
        # These two measure the OCR's raw reading against the text, before the
        # text corrects it: headers, footnotes and added passages lower them
        # however good the result. The result itself is the text layer line.
        log(f'  • تطابق قراءة الـ OCR الخام    : {mean_page_match:.2%} عبر {len(text_pages_meta)} صفحة نصية (قبل التصحيح بالنص)')
    if exact_vals:
        log(f'  • حروف OCR الخام المطابقة     : {mean_exact_match:.2%} (قبل التصحيح بالنص)')
    log(f'  • تفصيل كلمات الكتاب          : {source_words_count:,} كلمة من النص الأصلي + {added_words:,} كلمة مضافة من الـ PDF ({len(added_log)} مقطع/حاشية)')
    if 'text_layer' in report and report['text_layer'].get('after'):
        tl_b = report['text_layer']['before'].get('mean', 0)
        tl_a = report['text_layer']['after'].get('mean', 0)
        tl_med = report['text_layer']['after'].get('median', 0)
        log(f'  • جودة طبقة النص (PDFium)     : كانت {tl_b:.2%} قبل الطبخ ⟵ أصبحت {tl_a:.2%} بعد الطبخ (الوسيط: {tl_med:.2%})')
    if 'check_map' in report and 'boxes_confirmed_share' in report['check_map']:
        mc_info = report['check_map']
        log(f'  • تأكيد صناديق الكلمات هندسياً : {mc_info["boxes_confirmed_share"]:.2%} ({mc_info["boxes_confirmed"]:,}/{mc_info["boxes_tested"]:,} صندوق مطابق)')
    if 'check_pixels' in report:
        px_info = report['check_pixels']
        px_pct = px_info['mupdf_identical'] / max(px_info['pages'], 1)
        log(f'  • تطابق رسم البكسلات والصور   : {px_pct:.2%} ({px_info["mupdf_identical"]}/{px_info["pages"]} صفحة مطابقة 100%)')
    log('  ============================================================')
    log(f'  done in {report["seconds"]} s, report: {rp.name}')
    return report


def main(argv=None) -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    ap = argparse.ArgumentParser(prog='cook', description='Links a PDF with its text: one PDF with a correct '
                                 'text layer, bookmarks and a word map, drawn exactly as before.')
    ap.add_argument('paths', nargs='+', type=Path, help='PDF files or folders')
    ap.add_argument('--text', type=Path, help='Word (.docx), EPUB (.epub) or text file of the book (default: found next to the PDF)')
    ap.add_argument('--no-text', action='store_true', help='do not look for a text file')
    ap.add_argument('-o', '--out', type=Path, help='output PDF (one input only)')
    ap.add_argument('--title')
    ap.add_argument('--ocr', choices=['auto', 'off', 'force'], default='auto',
                    help='read pages drawn as pictures with OCR (auto: when needed and available)')
    ap.add_argument('--strong', choices=['auto', 'on', 'off'], default='auto',
                    help='Qari, the strong OCR, for the added passages, when it is on this machine '
                         '(auto: on the GPU while the CPU reads, and the book does not wait for it; '
                         'on: every passage, waiting for the GPU, or on a CPU at minutes per passage)')
    ap.add_argument('--pages', type=parse_pages,
                    help='only these pages of the PDF, e.g. 124,774 or 10-12: a quick trial, written to '
                         'BOOK.trial.nots.pdf; they come out as they would from the whole book')
    ap.add_argument('--no-check', action='store_true', help='skip the checks of the result')
    ap.add_argument('--debug-pages', default='', help='e.g. 21,100: draw word boxes of these pages to PNG')
    ap.add_argument('--keep-notes', action='store_true', help='keep editorial notes like [... مطابق للأصل]')
    ap.add_argument('--all-pages', action='store_true',
                    help='also read and write text on the pages before and after the text file\'s pages '
                         '(front matter, the printed index); by default they are left without text')
    ap.add_argument('--workers', type=int, default=None,
                    help='OCR processes at once (default: all CPU cores)')
    args = ap.parse_args(argv)
    ocr.WORKERS = args.workers
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')

    pdfs: list[Path] = []
    for p in args.paths:
        if p.is_dir():
            pdfs += sorted(x for x in p.glob('*.pdf') if not x.name.endswith('.nots.pdf'))
        else:
            pdfs.append(p)
    if args.out and len(pdfs) != 1:
        ap.error('-o needs exactly one input PDF')
    if args.pages and len(pdfs) != 1:
        ap.error('--pages needs exactly one input PDF')
    debug = [int(x) for x in args.debug_pages.split(',') if x.strip()]
    failed = 0
    for pdf in pdfs:
        text = None if args.no_text else (args.text or find_source(pdf))
        out = args.out or pdf.with_name(pdf.stem + ('.trial' if args.pages else '') + '.nots.pdf')
        try:
            cook(pdf, text, out, title=args.title, ocr_mode=args.ocr, check=not args.no_check,
                 debug_pages=debug, drop=[] if args.keep_notes else DEFAULT_DROP, strong=args.strong,
                 pages=args.pages, all_pages=args.all_pages)
        except Exception as e:  # keep going with the other books
            failed += 1
            log(f'  FAILED: {e!r}')
            if len(pdfs) == 1:
                raise
    return 1 if failed else 0
