"""Reads a PDF (and its source text when given), decodes and aligns every
page, and learns the glyphs that need correcting."""

from __future__ import annotations

import time
from dataclasses import dataclass, field

import pymupdf

from .align import (Decoder, DecodedPage, PageAlignment, SourceSkeleton, Votes,
                    WordBox, align, decode_page, detect_running_lines,
                    source_skeleton, word_boxes)
from .fonts import PdfFont, family_mark_ink, family_maps, read_fonts
from .glyphs import Glyph, page_glyphs, page_lines
from .source_text import SourceText


@dataclass
class PageResult:
    number: int
    glyphs: list[Glyph]
    images: int
    decoded: DecodedPage | None = None
    src: SourceSkeleton | None = None
    alignment: PageAlignment | None = None
    boxes: list[WordBox] = field(default_factory=list)
    kind: str = 'text'          # text | image | blank | ocr
    ratio: float = 0.0          # skeleton similarity with the source page


@dataclass
class Analysis:
    doc: pymupdf.Document
    fonts: dict[int, PdfFont]
    decoder: Decoder
    pages: list[PageResult]
    source: SourceText | None
    learned_rounds: list[int]
    seconds: float


def log(msg: str):
    print(msg, flush=True)


def analyze(doc: pymupdf.Document, source: SourceText | None, rounds: int = 10,
            verbose: bool = True) -> Analysis:
    t0 = time.time()
    fonts = read_fonts(doc)
    dec = Decoder(family_maps(fonts), family_mark_ink(fonts))
    pages = []
    for p in doc:
        pages.append(PageResult(number=p.number + 1, glyphs=page_glyphs(p),
                                images=len(p.get_images(full=False))))
    total_glyphs = sum(len(p.glyphs) for p in pages)
    if verbose:
        log(f'  {len(pages)} pages, {total_glyphs:,} glyphs, '
            f'{len(fonts)} fonts ({time.time() - t0:.1f}s)')

    learned_rounds = []
    if source is not None:
        n = min(len(pages), len(source.pages))
        srcs = [source_skeleton(source.pages[i]) for i in range(n)]
        if total_glyphs > 0:
            # A running header or footer repeats on most pages and has no
            # counterpart in the source (body-only) text; found once, up front,
            # from the raw (not yet corrected) glyphs, since the same wrong
            # glyphs decode to the same wrong text everywhere they repeat.
            for g in (g for pr in pages[:n] for g in pr.glyphs):
                g.text = dec.text(g)
            dec.running, dec.dotted_edges = detect_running_lines(
                [page_lines(pr.glyphs, dec.ink) for pr in pages[:n]])
            if verbose and (dec.running or dec.dotted_edges):
                log(f'  running headers/footers found: {len(dec.running)} fixed'
                    + (f', dot-leader {sorted(dec.dotted_edges)}' if dec.dotted_edges else '')
                    + (' — e.g. ' + '; '.join(repr(s) for s in list(dec.running)[:3]) if dec.running else ''))
            for r in range(rounds):
                votes = Votes()
                for i in range(n):
                    pr = pages[i]
                    pr.decoded = decode_page(pr.glyphs, dec)
                    pr.src = srcs[i]
                    pr.alignment = align(pr.decoded, pr.src, refine=False)
                    votes.collect(pr.decoded, pr.src, pr.alignment)
                fixes = votes.corrections(dec)
                learned_rounds.append(len(fixes))
                if verbose:
                    total = sum(p.alignment.matched for p in pages[:n])
                    size = sum(len(p.src.skel) for p in pages[:n])
                    log(f'  round {r + 1}: {total / max(size, 1):.4%} of source letters matched, '
                        f'{len(fixes)} glyph corrections learned'
                        + (' (blind from here)' if r == 0 and not dec.blind_unresolved else ''))
                if not fixes and dec.blind_unresolved:
                    break
                dec.learned.update(fixes)
                # From the second pass on, a glyph still unresolved shows as
                # nothing rather than its (likely wrong) guess: lucky
                # coincidences with the wrong guess can no longer be mistaken
                # for a match, so later passes learn from clean word-length
                # blocks instead of stalling around the noise.
                dec.blind_unresolved = True
        for i in range(n):
            pr = pages[i]
            if pr.decoded is None:
                pr.decoded = decode_page(pr.glyphs, dec)
            pr.src = srcs[i]
            pr.alignment = align(pr.decoded, pr.src, refine=True)
            pr.boxes = word_boxes(pr.decoded, pr.src, pr.alignment)
            pr.ratio = pr.alignment.ratio(len(pr.decoded.skel), len(pr.src.skel))
    else:
        for pr in pages:
            pr.decoded = decode_page(pr.glyphs, dec)
    for i, pr in enumerate(pages):
        has_src_words = source is not None and i < len(source.pages) and source.pages[i].words()
        if not pr.glyphs or not (pr.decoded and pr.decoded.skel):
            pr.kind = 'image' if pr.images else 'blank'
        elif source is not None and has_src_words and pr.ratio < 0.3 and pr.images:
            pr.kind = 'image'
    return Analysis(doc, fonts, dec, pages, source, learned_rounds, time.time() - t0)
