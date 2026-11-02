"""Decoding the page glyphs, aligning them with the source text, and
learning the glyphs the fonts could not explain.

Both sides are reduced to a "skeleton": the letters, digits and punctuation
only (no spaces, no diacritics, no tatweel), because those are what the two
sides share reliably. Aligning the skeletons page by page gives every
source letter its glyph on the page, hence every source word its box.
"""

from __future__ import annotations

import collections
import difflib
import unicodedata
from dataclasses import dataclass, field

from .fonts import MIRROR, base_family
from .glyphs import Glyph, page_lines
from .source_text import SourcePage

TATWEEL = 'ـ'


def keep(c: str) -> bool:
    """Whether a character belongs to the skeleton."""
    if c.isspace() or c == TATWEEL:
        return False
    cat = unicodedata.category(c)
    return cat not in ('Mn', 'Me', 'Cf', 'Cc')


def skeleton(s: str) -> str:
    return ''.join(c for c in s if keep(c))


class Decoder:
    """Text of each glyph: learned corrections first, then the font
    program's own tables, then the PDF's /ToUnicode."""

    def __init__(self, family_maps: dict[str, dict[int, str]],
                 mark_ink: dict[str, dict[int, tuple[float, float]]] | None = None):
        self.family_maps = family_maps
        self.mark_ink = mark_ink or {}
        self.learned: dict[tuple[str, int], str] = {}

    def ink(self, g: Glyph) -> tuple[float, float] | None:
        """Horizontal ink extent of a diacritic glyph, in font sizes from
        its origin, when the font outline is known."""
        m = self.mark_ink.get(g.font)
        return m.get(g.gid) if m else None

    def from_font(self, font: str, gid: int) -> str | None:
        fm = self.family_maps.get(font)
        return fm.get(gid) if fm is not None else None

    def text(self, g: Glyph) -> str:
        k = (g.font, g.gid)
        if k in self.learned:
            return self.learned[k]
        s = self.from_font(g.font, g.gid)
        return g.tu if s is None else s

    def source(self, font: str, gid: int) -> str:
        if (font, gid) in self.learned:
            return 'learned'
        return 'tounicode' if self.from_font(font, gid) is None else 'font'


def _leader_dots(texts: list[str]) -> list[bool]:
    """Dot leaders of a table of contents ("........"): three or more dots
    in a row, which the source text does not have."""
    out = [False] * len(texts)
    i = 0
    while i < len(texts):
        j = i
        while j < len(texts) and texts[j] in ('.', '…', '·', '. '):
            j += 1
        if j - i >= 3:
            out[i:j] = [True] * (j - i)
        i = max(j, i + 1)
    return out


@dataclass
class DecodedPage:
    skel: str = ''                                   # PDF skeleton
    owner: list[Glyph] = field(default_factory=list)  # glyph of each skeleton char
    text: str = ''                                   # readable logical text
    lines: list = field(default_factory=list)         # [(glyph, in_rtl_run)] per line


def decode_page(glyphs: list[Glyph], dec: Decoder) -> DecodedPage:
    for g in glyphs:
        g.text = dec.text(g)
    out = DecodedPage()
    skel: list[str] = []
    lines_text: list[str] = []
    out.lines = page_lines(glyphs, dec.ink)
    for line in out.lines:
        texts = [MIRROR.get(g.text, g.text) if rtl else g.text for g, rtl in line]
        leader = _leader_dots(texts)
        parts = []
        for k, (g, _) in enumerate(line):
            t = texts[k]
            parts.append(t + ''.join(m.text for m in g.marks))
            if leader[k]:
                continue
            for c in t:
                if keep(c):
                    skel.append(c)
                    out.owner.append(g)
        lines_text.append(''.join(parts).strip())
    out.skel = ''.join(skel)
    out.text = '\n'.join(t for t in lines_text if t)
    return out


@dataclass
class SourceSkeleton:
    words: list[str]
    skel: str
    word_of: list[int]  # word index of each skeleton char


def source_skeleton(page: SourcePage) -> SourceSkeleton:
    words = page.words()
    chars: list[str] = []
    word_of: list[int] = []
    for wi, w in enumerate(words):
        leader = _leader_dots(list(w))
        for k, c in enumerate(w):
            if keep(c) and not leader[k]:
                chars.append(c)
                word_of.append(wi)
    return SourceSkeleton(words, ''.join(chars), word_of)


@dataclass
class PageAlignment:
    ops: list[tuple[str, int, int, int, int]]
    pdf_of_src: list[int]      # PDF skeleton index of each source skeleton char, -1 if none
    exact_of_src: list[bool]   # matched exactly (not guessed inside a replaced block)
    matched: int               # characters in equal blocks

    def ratio(self, n_pdf: int, n_src: int) -> float:
        return 2 * self.matched / (n_pdf + n_src) if n_pdf + n_src else 1.0


def align(pdf: DecodedPage, src: SourceSkeleton) -> PageAlignment:
    sm = difflib.SequenceMatcher(None, pdf.skel, src.skel, autojunk=False)
    ops = sm.get_opcodes()
    pdf_of = [-1] * len(src.skel)
    exact = [False] * len(src.skel)
    matched = 0
    for tag, i1, i2, j1, j2 in ops:
        if tag == 'equal':
            matched += i2 - i1
            for k in range(j2 - j1):
                pdf_of[j1 + k] = i1 + k
                exact[j1 + k] = True
        elif tag == 'replace':
            n, m = i2 - i1, j2 - j1
            for k in range(m):
                pdf_of[j1 + k] = i1 + (k if n == m else k * n // m)
    return PageAlignment(ops, pdf_of, exact, matched)


class Votes:
    """What the source text says each glyph is."""

    def __init__(self):
        self.seen: dict[tuple[str, int], collections.Counter] = collections.defaultdict(collections.Counter)

    def add(self, g: Glyph, text: str):
        self.seen[(g.font, g.gid)][text] += 1

    def collect(self, pdf: DecodedPage, src: SourceSkeleton, al: PageAlignment):
        owner = pdf.owner
        n = len(owner)
        for tag, i1, i2, j1, j2 in al.ops:
            if tag == 'equal':
                prev = None
                for i in range(i1, i2):
                    g = owner[i]
                    if g is not prev:
                        # Only whole glyphs inside the block confirm their text.
                        s = skeleton(g.text)
                        first = i == 0 or owner[i - 1] is not g
                        if first and i + len(s) <= i2:
                            self.add(g, s)
                        prev = g
            elif tag == 'replace':
                # The block must start and end on glyph boundaries.
                if (i1 > 0 and owner[i1 - 1] is owner[i1]) or (i2 < n and owner[i2] is owner[i2 - 1]):
                    continue
                glyphs = []
                for i in range(i1, i2):
                    if not glyphs or glyphs[-1] is not owner[i]:
                        glyphs.append(owner[i])
                want = src.skel[j1:j2]
                if any(g.text in MIRROR or any(c in MIRROR for c in want) for g in glyphs):
                    continue
                if len(glyphs) == 1:
                    self.add(glyphs[0], want)
                elif len(glyphs) == len(want) and all(len(skeleton(g.text)) == 1 for g in glyphs):
                    for g, c in zip(glyphs, want):
                        self.add(g, c)

    def corrections(self, dec: Decoder, min_votes: int = 2, share: float = 0.6) -> dict[tuple[str, int], str]:
        """Glyphs whose text the source contradicts clearly."""
        out = {}
        for k, cnt in self.seen.items():
            total = sum(cnt.values())
            best, c = cnt.most_common(1)[0]
            if not best or c < min_votes or c < share * total:
                continue
            g = Glyph(seq=0, font=k[0], gid=k[1], tu='', x=0, y=0, bbox=(0, 0, 0, 0), size=0)
            current = dec.text(g)
            if skeleton(current) != best and k not in out:
                out[k] = best
        return out


def pdf_words(pdf: DecodedPage) -> tuple[str, list[tuple[float, float, float, float]]]:
    """The page's own words (when there is no source text): split at space
    glyphs, one line per paragraph, each word with its box."""
    lines_out: list[str] = []
    boxes: list[tuple[float, float, float, float]] = []
    for line in pdf.lines:
        words: list[str] = []
        cur: list[tuple[Glyph, str]] = []

        def flush():
            text = ''.join(t for _, t in cur).strip()
            if text and skeleton(text):
                for part in text.split():
                    words.append(part)
                    gs = [g for g, _ in cur]
                    boxes.append((min(g.bbox[0] for g in gs), min(g.bbox[1] for g in gs),
                                  max(g.bbox[2] for g in gs), max(g.bbox[3] for g in gs)))
            cur.clear()

        for g, rtl in line:
            t = MIRROR.get(g.text, g.text) if rtl else g.text
            if not t or t.isspace():
                flush()
                continue
            cur.append((g, t + ''.join(m.text for m in g.marks)))
        flush()
        if words:
            lines_out.append(' '.join(words))
    return '\n'.join(lines_out), boxes


@dataclass
class WordBox:
    rect: tuple[float, float, float, float] | None
    exact: float  # share of the word's letters matched exactly


def word_boxes(pdf: DecodedPage, src: SourceSkeleton, al: PageAlignment) -> list[WordBox]:
    per_word: list[list[int]] = [[] for _ in src.words]
    for j, wi in enumerate(src.word_of):
        per_word[wi].append(j)
    out = []
    for js in per_word:
        if not js:
            out.append(WordBox(None, 0.0))
            continue
        glyphs: list[Glyph] = []
        for j in js:
            i = al.pdf_of_src[j]
            if i >= 0:
                g = pdf.owner[i]
                if not glyphs or glyphs[-1] is not g:
                    glyphs.append(g)
        exact = sum(al.exact_of_src[j] for j in js) / len(js)
        if not glyphs:
            out.append(WordBox(None, exact))
            continue
        by_line: dict[int, list[Glyph]] = collections.defaultdict(list)
        for g in glyphs:
            if g.bbox[2] > g.bbox[0]:  # zero-width glyphs say nothing about the place
                by_line[g.line].append(g)
        if not by_line:
            out.append(WordBox(None, exact))
            continue
        best = max(by_line.values(), key=len)
        x0 = min(g.bbox[0] for g in best)
        y0 = min(g.bbox[1] for g in best)
        x1 = max(g.bbox[2] for g in best)
        y1 = max(g.bbox[3] for g in best)
        for g in best:
            for m in g.marks:  # marks may stick out above or below
                y0 = min(y0, m.bbox[1])
                y1 = max(y1, m.bbox[3])
        out.append(WordBox((x0, y0, x1, y1), exact))
    return out
