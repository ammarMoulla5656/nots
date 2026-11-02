"""nots-cook command line.

    python cook.py BOOK.pdf [--text BOOK.docx] [-o OUT.pdf]
    python cook.py FOLDER            # every PDF in the folder, paired with
                                     # the Word file of the same book

Writes BOOK.nots.pdf next to the book (or OUT.pdf) and BOOK.nots.report.json.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import sys
import time
from pathlib import Path

import pymupdf

from . import __version__, ocr, verify, wordmap, writer
from .pipeline import Analysis, analyze, log
from .source_text import DEFAULT_DROP, SourceText, read_source
from .align import pdf_words


def find_source(pdf: Path) -> Path | None:
    """The Word (or text) file of the same book next to the PDF: the only
    one there, or the one whose name is closest."""
    cands = [p for p in pdf.parent.iterdir()
             if p.suffix.lower() in ('.docx', '.txt') and not p.name.startswith('~$')]
    if not cands:
        return None
    if len(cands) == 1:
        return cands[0]
    best = max(cands, key=lambda p: difflib.SequenceMatcher(None, p.stem, pdf.stem).ratio())
    return best


def heading_words(source: SourceText) -> list[dict]:
    """Headings with the index of their first word in the whole book."""
    starts = []
    n = 0
    for page in source.pages:
        starts.append(n)
        n += len(page.words())
    out = []
    for h in source.headings:
        page = source.pages[h.page - 1]
        before = sum(len(p.split()) for p in page.paragraphs[:h.paragraph] if p)
        out.append({'t': h.title, 'l': h.level, 'p': h.page, 'w': starts[h.page - 1] + before})
    return out


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


def cook(pdf_path: Path, text_path: Path | None, out_path: Path, *, title: str | None,
         ocr_mode: str, check: bool, debug_pages: list[int], drop: list[str]) -> dict:
    t0 = time.time()
    log(f'\n== {pdf_path.name}')
    source = None
    if text_path:
        source = read_source(text_path, drop)
        log(f'  text: {text_path.name}: {len(source.pages)} pages, '
            f'{sum(len(p.words()) for p in source.pages):,} words, {len(source.headings)} headings')
    doc = pymupdf.open(pdf_path)
    if source and len(source.pages) != doc.page_count:
        log(f'  WARNING: the text has {len(source.pages)} pages and the PDF {doc.page_count}: '
            f'pages are matched by number, check the result.')
    a: Analysis = analyze(doc, source)

    # Pages drawn as pictures: read them with OCR to place their words.
    ocr_pages = [pr for pr in a.pages if pr.kind == 'image' and (
        source is None or (pr.number <= len(source.pages) and source.pages[pr.number - 1].words()))]
    ocr_info = {}
    if ocr_pages and ocr_mode != 'off':
        ocr_info = ocr.place_words(doc, a, ocr_pages, source, force=ocr_mode == 'force')

    map_pages = []
    method = 'fonts+text' if source else 'fonts'
    for i, pr in enumerate(a.pages):
        size = (doc[i].rect.width, doc[i].rect.height)
        if source and i < len(source.pages):
            text = source.pages[i].text
            boxes = [b.rect for b in pr.boxes] if pr.boxes else [None] * len(text.split())
        elif pr.ocr_words is not None:
            text = ' '.join(w for w, _ in pr.ocr_words)
            boxes = [b for _, b in pr.ocr_words]
        else:
            text, boxes = pdf_words(pr.decoded) if pr.decoded else ('', [])
        if source and i < len(source.pages) and not text.split():
            kind = 'blank' if not pr.glyphs else pr.kind
        else:
            kind = pr.kind
        map_pages.append(wordmap.MapPage(kind, text, boxes, size))

    title = title or (doc.metadata or {}).get('title') or pdf_path.stem
    headings = heading_words(source) if source else []
    m = wordmap.build(title=title, pages=map_pages, headings=headings,
                      source_pdf=pdf_path.name, source_pdf_id=wordmap.fingerprint(str(pdf_path)),
                      source_text=text_path.name if text_path else None, method=method,
                      generator=f'nots-cook {__version__}')
    data = wordmap.dumps(m)

    font_changes = writer.fix_text_layer(doc, a.fonts, a.decoder)
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

    report = {
        'tool': f'nots-cook {__version__}',
        'input': {'pdf': str(pdf_path), 'text': str(text_path) if text_path else None,
                  'pages': len(a.pages), 'bytes': in_size},
        'output': {'pdf': str(out_path), 'bytes': out_size, 'map_bytes_raw': len(data)},
        'words': words, 'placed': placed, 'bookmarks': toc,
        'learned_glyphs': len(a.decoder.learned),
        'learned': {f'{k[0]}#{k[1]}': v for k, v in sorted(a.decoder.learned.items())},
        'fonts_fixed': font_changes,
        'ocr': ocr_info,
        'pages': [{
            'page': pr.number, 'kind': map_pages[i].kind, 'match': round(pr.ratio, 4),
            'words': len(map_pages[i].boxes),
            'placed': sum(1 for b in map_pages[i].boxes if b),
            'exact': round(sum(b.exact for b in pr.boxes) / len(pr.boxes), 4) if pr.boxes else None,
        } for i, pr in enumerate(a.pages)],
    }
    if check:
        log('  checking ...')
        px = verify.check_pixels(str(pdf_path), str(out_path))
        log(f'  pixels: {px["mupdf_identical"]}/{px["pages"]} pages identical (MuPDF)'
            + (f', PDFium sample {px["pdfium_checked"] - len(px["pdfium_different"])}/{px["pdfium_checked"]} identical'
               if 'pdfium_checked' in px else ''))
        report['check_pixels'] = px
        if source:
            texts = [p.text for p in source.pages]
            before, after = verify.text_quality(str(pdf_path), texts), verify.text_quality(str(out_path), texts)
            if before:
                log(f'  text layer (PDFium) vs the source: {before["mean"]:.1%} before, {after["mean"]:.1%} after')
            report['text_layer'] = {'before': before, 'after': after}
        mc = verify.check_map(str(out_path))
        report['check_map'] = mc
        if mc.get('found'):
            log(f'  word map: read back in {mc["read_ms"]} ms, {mc["words"]:,} words, '
                f'problems: {mc["problems"] or "none"}'
                + (f', boxes confirmed by PDFium: {mc["boxes_confirmed_share"]:.2%} of {mc["boxes_tested"]}'
                   if 'boxes_tested' in mc else ''))
        else:
            log('  ERROR: word map not found in the output')
    if debug_pages:
        folder = out_path.with_name(out_path.stem + '.debug')
        debug_images(str(out_path), m, debug_pages, folder)
        log(f'  debug pages in {folder}')
    report['seconds'] = round(time.time() - t0, 1)
    rp = out_path.with_name(out_path.stem + '.report.json')
    rp.write_text(json.dumps(report, ensure_ascii=False, indent=1), 'utf-8')
    log(f'  done in {report["seconds"]} s, report: {rp.name}')
    return report


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog='cook', description='Links a PDF with its text: one PDF with a correct '
                                 'text layer, bookmarks and a word map, drawn exactly as before.')
    ap.add_argument('paths', nargs='+', type=Path, help='PDF files or folders')
    ap.add_argument('--text', type=Path, help='Word (.docx) or text file of the book (default: found next to the PDF)')
    ap.add_argument('--no-text', action='store_true', help='do not look for a text file')
    ap.add_argument('-o', '--out', type=Path, help='output PDF (one input only)')
    ap.add_argument('--title')
    ap.add_argument('--ocr', choices=['auto', 'off', 'force'], default='auto',
                    help='read pages drawn as pictures with OCR (auto: when needed and available)')
    ap.add_argument('--no-check', action='store_true', help='skip the checks of the result')
    ap.add_argument('--debug-pages', default='', help='e.g. 21,100: draw word boxes of these pages to PNG')
    ap.add_argument('--keep-notes', action='store_true', help='keep editorial notes like [... مطابق للأصل]')
    args = ap.parse_args(argv)
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
    debug = [int(x) for x in args.debug_pages.split(',') if x.strip()]
    failed = 0
    for pdf in pdfs:
        text = None if args.no_text else (args.text or find_source(pdf))
        out = args.out or pdf.with_name(pdf.stem + '.nots.pdf')
        try:
            cook(pdf, text, out, title=args.title, ocr_mode=args.ocr, check=not args.no_check,
                 debug_pages=debug, drop=[] if args.keep_notes else DEFAULT_DROP)
        except Exception as e:  # keep going with the other books
            failed += 1
            log(f'  FAILED: {e!r}')
            if len(pdfs) == 1:
                raise
    return 1 if failed else 0
