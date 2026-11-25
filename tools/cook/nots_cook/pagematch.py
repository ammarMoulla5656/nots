"""Matches a source text's own pages to a PDF's pages, when they are not
simply 1-to-1 (a scanned PDF with a few unnumbered pages of cover and
front matter before its text starts, read against an EPUB or other source
whose own page numbers start elsewhere, or run past where the source's
text ends into an index the source does not have).

The offset is found empirically: a handful of PDF pages, spread through
the book, are read with OCR and located inside the source text by content,
not by trusting any printed or metadata page number to agree with the
PDF's page count.
"""

from __future__ import annotations

import collections

import pymupdf

from .align import skeleton
from .engines import Reader, merge
from .source_text import SourcePage, SourceText


RUN = 12  # letters: a run this long seldom repeats on another page by chance


def _shared_runs(samples: dict[int, str], pages: list[str]) -> dict[int, collections.Counter]:
    """For each sample, how many runs of [RUN] letters it shares with each
    source page. One pass over the source, however long the book is."""
    wanted: dict[str, list[int]] = collections.defaultdict(list)
    for number, text in samples.items():
        for run in {text[i:i + RUN] for i in range(len(text) - RUN + 1)}:
            wanted[run].append(number)
    hits: dict[int, collections.Counter] = {n: collections.Counter() for n in samples}
    for i, page in enumerate(pages):
        for k in range(len(page) - RUN + 1):
            for number in wanted.get(page[k:k + RUN], ()):
                hits[number][i] += 1
    return hits


def detect_offset(doc: pymupdf.Document, source: SourceText, reader: Reader, *,
                   samples: int = 10, min_runs: int = 20, min_share: float = 0.4, log=None) -> int | None:
    """The offset such that PDF page p (1-based) holds source.pages[p - 1
    - offset], found from [samples] pages spread through the book. Returns
    None when fewer than [min_share] of the samples agree to be confident."""
    pages = [skeleton(p.text) for p in source.pages]
    if not any(pages):
        return None
    step = max(1, doc.page_count // samples)
    numbers = list(range(step, doc.page_count + 1, step))
    read = reader.read(numbers, fast=True)
    texts = {}
    for pdf_page in numbers:
        got = read[pdf_page]
        words = merge(got.get('tesseract') or got.get('mupdf') or [], got.get('windows') or [])
        text = skeleton(' '.join(w.text for w in words))
        if len(text) >= 40:
            texts[pdf_page] = text
    votes: collections.Counter[int] = collections.Counter()
    for pdf_page, hits in _shared_runs(texts, pages).items():
        if not hits:
            continue
        page, runs = hits.most_common(1)[0]
        if runs < min_runs:
            continue
        offset = (pdf_page - 1) - page
        votes[offset] += 1
        if log:
            log(f'    offset sample: PDF page {pdf_page} -> source page {page + 1} '
                f'(offset {offset}, {runs} shared runs)')
    if not votes:
        return None
    best, count = votes.most_common(1)[0]
    if count < max(2, sum(votes.values()) * min_share):
        return None
    return best


def _increasing(pairs: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """The longest run of (pdf page, source page) pairs in which the source
    page only grows: a page matched by chance to a far-off page drops out."""
    import bisect
    tails: list[int] = []          # smallest source page ending a run of each length
    tail_at: list[int] = []        # index in [pairs] of that pair
    prev = [-1] * len(pairs)
    for k, (_, i) in enumerate(pairs):
        j = bisect.bisect_left(tails, i)
        if j == len(tails):
            tails.append(i); tail_at.append(k)
        else:
            tails[j] = i; tail_at[j] = k
        prev[k] = tail_at[j - 1] if j else -1
    out, k = [], tail_at[-1] if tail_at else -1
    while k >= 0:
        out.append(pairs[k]); k = prev[k]
    return out[::-1]


def align_pages(doc: pymupdf.Document, source: SourceText, reader: Reader, *,
                min_runs: int = 12, log=None) -> tuple[SourceText, dict] | None:
    """Matches each PDF page to the source page it shows, by content, when
    the two do not differ by one constant offset: a scan with a few pages
    inserted or missing here and there drifts against the text's numbering
    (al-Mizan-like books: offset +3 at page 40, +8 at page 450), and a page-
    for-page reading then puts every word on the wrong page (placed 0%).

    All pages are read with the fast engine (cached for the main pass), each
    one's letters are looked up in the source's pages, and the matches that
    break the order are dropped. Returns the source re-indexed so that PDF
    page p is pages[p - 1], and what was found; None when too few pages match
    for the text to be this PDF's."""
    pages = [skeleton(p.text) for p in source.pages]
    if not any(pages):
        return None
    n = doc.page_count
    numbers = list(range(1, n + 1))
    read = reader.read(numbers, fast=True)
    texts: dict[int, str] = {}
    for p in numbers:
        got = read[p]
        words = merge(got.get('tesseract') or got.get('mupdf') or [], got.get('windows') or [])
        text = skeleton(' '.join(w.text for w in words))
        if len(text) >= 60:
            texts[p] = text
    hits = _shared_runs(texts, pages)
    found = []
    for p in sorted(hits):
        if hits[p]:
            i, runs = hits[p].most_common(1)[0]
            if runs >= min_runs:
                found.append((p, i))
    anchors = _increasing(found)
    stats = {'pages': n, 'read': len(texts), 'matched': len(anchors)}
    if not anchors or len(anchors) < 0.25 * max(len(texts), 1):
        stats['matched_share'] = len(anchors) / max(len(texts), 1)
        return None

    # Between two anchors the pages follow one another; where the two sides
    # differ in length, the extra pages stand at the end of the gap (an extra
    # PDF page is left empty, an extra source page is left out: counted).
    target: dict[int, int] = {}          # pdf page -> source index
    for k, (p, i) in enumerate(anchors):
        target[p] = i
        p2, i2 = anchors[k + 1] if k + 1 < len(anchors) else (n + 1, len(pages))
        for d in range(1, min(p2 - p, i2 - i)):
            target[p + d] = i + d
    p0, i0 = anchors[0]
    for d in range(1, min(p0, i0 + 1)):      # before the first anchor, the same step backwards
        target[p0 - d] = i0 - d
    used = set(target.values())
    lost = [i for i, t in enumerate(pages) if t and i not in used]
    new_pages = [SourcePage() for _ in range(n)]
    for p, i in target.items():
        if 1 <= p <= n and 0 <= i < len(source.pages):
            new_pages[p - 1] = source.pages[i]
    where = {i: p for p, i in target.items()}
    headings = []
    for h in source.headings:
        i = h.page - 1
        while i >= 0 and i not in where:      # a heading on a page left out goes to the page before it
            i -= 1
        if i >= 0:
            headings.append(type(h)(h.title, h.level, where[i], h.paragraph if i == h.page - 1 else 0))
    offs = [(p - 1) - i for p, i in anchors]
    stats.update(matched_share=len(anchors) / max(len(texts), 1), source_pages_left_out=len(lost),
                 offset_first=offs[0], offset_last=offs[-1], offset_min=min(offs), offset_max=max(offs))
    return SourceText(pages=new_pages, headings=headings, name=source.name), stats


def apply_offset(doc: pymupdf.Document, source: SourceText, offset: int) -> SourceText:
    """A copy of [source] with .pages (and headings) re-indexed so that
    PDF page p (1-based) is pages[p - 1]: pages the PDF has and the source
    does not (before or after the source's own page range) become empty."""
    n = doc.page_count
    pages = [SourcePage() for _ in range(n)]
    for i, p in enumerate(source.pages):
        j = i + offset
        if 0 <= j < n:
            pages[j] = p
    headings = []
    for h in source.headings:
        p = h.page + offset
        if 1 <= p <= n:
            headings.append(type(h)(h.title, h.level, p, h.paragraph))
    return SourceText(pages=pages, headings=headings, name=source.name)
