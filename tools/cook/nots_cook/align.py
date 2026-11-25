"""Decoding the page glyphs, aligning them with the source text, and
learning the glyphs the fonts could not explain.

Both sides are reduced to a "skeleton": the letters, digits and punctuation
only (no spaces, no diacritics, no tatweel), because those are what the two
sides share reliably. Aligning the skeletons page by page gives every
source letter its glyph on the page, hence every source word its box.
"""

from __future__ import annotations

import collections
try:  # the same algorithm compiled: identical results, ~11x faster
    import cydifflib as difflib
except ImportError:
    import difflib
import re
import unicodedata
from dataclasses import dataclass, field

from .fonts import MIRROR, base_family
from .glyphs import Glyph, is_mark, page_lines
from .source_text import SourcePage

TATWEEL = 'ـ'

_ALIGN_FOLD = str.maketrans({
    'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا',
    'ى': 'ي', 'ئ': 'ي', 'ؤ': 'و', 'ة': 'ه',
})

_ALIGN_RASM = str.maketrans({
    'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا',
    'ب': 'ب', 'ت': 'ب', 'ث': 'ب', 'ن': 'ب', 'ي': 'ب', 'ى': 'ب', 'ئ': 'ب',
    'ج': 'ح', 'ح': 'ح', 'خ': 'ح',
    'د': 'د', 'ذ': 'د',
    'ر': 'ر', 'ز': 'ر',
    'س': 'س', 'ش': 'س',
    'ص': 'ص', 'ض': 'ص',
    'ط': 'ط', 'ظ': 'ظ',
    'ع': 'ع', 'غ': 'ع',
    'ف': 'ف', 'ق': 'ف',
    'ك': 'ل', 'ل': 'ل',
    'ه': 'ه', 'ة': 'ه',
    'ؤ': 'و', 'و': 'و',
})

# Stands in for a glyph whose text is only a guess (the PDF's own, possibly
# broken, /ToUnicode): it can never equal a character of the source text, so
# a guess can never spuriously "match" and mislead the alignment. Without
# this, a handful of lucky coincidences between wrong guesses and real
# letters can both stall learning (no clean word-length blocks left to
# learn from) and, worse, get voted in as if confirmed.
UNRESOLVED = '\ufffd'


def keep(c: str) -> bool:
    """Whether a character belongs to the skeleton."""
    if c.isspace() or c in (TATWEEL, '*'):
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
        self.zero_marks: set[tuple[str, int]] = set()
        # Once there has been a first pass to learn from (see pipeline.py),
        # a glyph still unresolved stops showing its guess during decoding:
        # better to show nothing than to risk the alignment trusting it.
        self.blind_unresolved = False
        # Running headers/footers, found once up front and excluded from
        # every page's skeleton from then on: see detect_running_lines.
        self.running: set[str] = set()         # exact signatures
        self.dotted_edges: set[str] = set()    # {'first', 'last'}: a dot-leader row there is always one

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
        if s is not None:
            return s
        if k in self.zero_marks:
            return '\u064e'
        # When the font program gave no character map (e.g. a PUA symbol
        # font) and has no diacritic outline for this glyph, a /ToUnicode
        # entry that claims to be a combining mark cannot be trusted without
        # confirming whether the glyph is a zero-advance mark or a base letter.
        if is_mark(g.tu) and not self.ink(g):
            return UNRESOLVED
        return g.tu

    def source(self, font: str, gid: int) -> str:
        if (font, gid) in self.learned:
            return 'learned'
        return 'tounicode' if self.from_font(font, gid) is None else 'font'

    def resolved(self, g: Glyph) -> bool:
        """Whether [g]'s text is known (learned, or from the font program)
        rather than guessed from the PDF's own (possibly broken)
        /ToUnicode."""
        return (g.font, g.gid) in self.learned or self.from_font(g.font, g.gid) is not None


def _line_text(line: list[tuple[Glyph, bool]]) -> str:
    parts = []
    for g, rtl in line:
        t = MIRROR.get(g.text, g.text) if rtl else g.text
        parts.append(t + ''.join(m.text for m in g.marks))
    return ''.join(parts)


def line_signature(line: list[tuple[Glyph, bool]]) -> str:
    """A line's text, normalised so the same running header or footer gives
    the same signature on every page: digit runs (the page number) become
    one '#', dot leaders (whose length varies with the page number's own
    width) disappear, white space collapses. Works even before any glyph is
    correctly decoded, since the same (wrong) glyphs repeat the same
    (wrong) text every time."""
    text = _line_text(line)
    text = re.sub(r'[0-9٠-٩۰-۹]+', '#', text)
    text = re.sub(r'[.…·]+', ' ', text)
    return re.sub(r'\s+', ' ', text).strip(' -_|')


def detect_running_lines(pages_lines: list[list[list[tuple[Glyph, bool]]]],
                          min_len: int = 3, share: float = 0.4,
                          ) -> tuple[set[str], set[str]]:
    """Two kinds of running header/footer, found from a page's first and
    last lines only, which the source (body-only) text does not contain
    and which would otherwise sit in the skeleton as letters with nothing
    on the other side to match:

    - signatures (see [line_signature]) that repeat, verbatim but for the
      page number, on a good share of the book's pages (a constant book or
      part title);
    - 'first'/'last': that position holds a dot leader (title ... page
      number) on a good share of pages, even where the title itself
      changes often (a chapter title, say, changing every few pages) and
      so never repeats often enough to be caught by the first method."""
    counts: collections.Counter[str] = collections.Counter()
    dotted = collections.Counter()
    pages_with_lines = 0
    for lines in pages_lines:
        if not lines:
            continue
        pages_with_lines += 1
        for pos, line in (('first', lines[0]), ('last', lines[-1])):
            sig = line_signature(line)
            if len(sig) >= min_len:
                counts[sig] += 1
            texts = [MIRROR.get(g.text, g.text) if rtl else g.text for g, rtl in line]
            if any(_leader_dots(texts)):
                dotted[pos] += 1
    threshold = max(4, share * pages_with_lines)
    sigs = {s for s, c in counts.items() if c >= threshold}
    positions = {p for p, c in dotted.items() if c >= threshold}
    return sigs, positions


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
    n_lines = len(out.lines)
    for li, line in enumerate(out.lines):
        for g, _ in line:
            for m in g.marks:
                if is_mark(m.tu):
                    m.text = m.tu
                elif not is_mark(m.text):
                    dec.zero_marks.add((m.font, m.gid))
                    m.text = ''
        # A running header or footer (page furniture, not book text) is
        # only ever the page's first or last line.
        texts = [MIRROR.get(g.text, g.text) if rtl else g.text for g, rtl in line]
        leader = _leader_dots(texts)
        running = False
        if li == 0 or li == n_lines - 1:
            pos = 'first' if li == 0 else 'last'
            running = (line_signature(line) in dec.running) or (
                pos in dec.dotted_edges and any(leader))
        parts = []
        for k, (g, _) in enumerate(line):
            t = texts[k]
            parts.append(t + ''.join(m.text for m in g.marks))
            if leader[k] or running:
                continue
            blind = dec.blind_unresolved and not dec.resolved(g)
            for c in t:
                if keep(c):
                    skel.append(UNRESOLVED if blind else c)
                    out.owner.append(g)
        if not running:
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


def _clean_spurious_equals(ops: list[tuple[str, int, int, int, int]],
                           owner: list[Glyph]) -> list[tuple[str, int, int, int, int]]:
    """Demotes tiny (<= 3 char) 'equal' blocks that jump across many lines
    and a large excess of PDF characters (such as a 2-3 letter coincidence
    inside footnotes at the bottom of the page)."""
    if not owner or len(ops) < 2:
        return ops
    cleaned: list[list] = [list(op) for op in ops]
    for idx, (tag, i1, i2, j1, j2) in enumerate(cleaned):
        if tag != 'equal' or (i2 - i1) > 3 or i2 == i1:
            continue
        # Check preceding replace/delete gap
        prev_i = cleaned[idx - 1][1] if idx > 0 else i1
        prev_j = cleaned[idx - 1][3] if idx > 0 else j1
        di_before = i1 - prev_i
        dj_before = j1 - prev_j
        line_before = abs(owner[i1].line - owner[max(0, prev_i - 1)].line) if prev_i > 0 else 0

        # Check following replace/delete gap
        next_i = cleaned[idx + 1][2] if idx + 1 < len(cleaned) else i2
        next_j = cleaned[idx + 1][4] if idx + 1 < len(cleaned) else j2
        di_after = next_i - i2
        dj_after = next_j - j2
        line_after = (abs(owner[min(len(owner) - 1, next_i)].line - owner[i2 - 1].line)
                      if next_i < len(owner) else 0)

        if (di_before > dj_before + 30 and line_before >= 3) or (
                di_after > dj_after + 30 and line_after >= 3):
            cleaned[idx][0] = 'replace'

    # Coalesce adjacent non-equal blocks into single replace/delete/insert ops
    merged: list[tuple[str, int, int, int, int]] = []
    for tag, i1, i2, j1, j2 in cleaned:
        if tag == 'equal':
            merged.append((tag, i1, i2, j1, j2))
        elif merged and merged[-1][0] != 'equal':
            _, pi1, _, pj1, _ = merged[-1]
            ni, nj = i2 - pi1, j2 - pj1
            ntag = 'replace' if (ni and nj) else ('delete' if ni else 'insert')
            merged[-1] = (ntag, pi1, i2, pj1, j2)
        else:
            ni, nj = i2 - i1, j2 - j1
            ntag = 'replace' if (ni and nj) else ('delete' if ni else 'insert')
            merged.append((ntag, i1, i2, j1, j2))
    return merged


def _align_replace_block(pdf_skel: str, src_skel: str, owner: list[Glyph],
                         i1: int, i2: int, j1: int, j2: int,
                         pdf_of: list[int], exact: list[bool]) -> int:
    """Refines a 'replace' block using folded Arabic letters first, then
    dotless Arabic rasm shapes, and only interpolates locally when lengths
    and line spans are compatible."""
    n, m = i2 - i1, j2 - j1
    if n <= 0 or m <= 0:
        return 0
    # When the PDF side has a large excess (e.g. unreferenced footnotes at
    # the bottom of the page after the source text ends), restrict the PDF
    # window to the local neighborhood of the adjacent anchor.
    if n > m + 35:
        local_span = max(m * 2 + 16, 24)
        if i1 > 0:
            i2 = min(i2, i1 + local_span)
        elif i2 < len(pdf_skel):
            i1 = max(i1, i2 - local_span)
        n = i2 - i1

    extra_matched = 0
    p_fold = pdf_skel[i1:i2].translate(_ALIGN_FOLD)
    s_fold = src_skel[j1:j2].translate(_ALIGN_FOLD)
    sm1 = difflib.SequenceMatcher(None, p_fold, s_fold, autojunk=False)
    for tag1, a1, a2, b1, b2 in sm1.get_opcodes():
        if tag1 == 'equal':
            extra_matched += a2 - a1
            for k in range(b2 - b1):
                pdf_of[j1 + b1 + k] = i1 + a1 + k
                exact[j1 + b1 + k] = True
        elif tag1 == 'replace':
            p_rasm = pdf_skel[i1 + a1:i1 + a2].translate(_ALIGN_RASM)
            s_rasm = src_skel[j1 + b1:j1 + b2].translate(_ALIGN_RASM)
            sm2 = difflib.SequenceMatcher(None, p_rasm, s_rasm, autojunk=False)
            for tag2, c1, c2, d1, d2 in sm2.get_opcodes():
                p0, p1 = i1 + a1 + c1, i1 + a1 + c2
                s0, s1 = j1 + b1 + d1, j1 + b1 + d2
                sn, sm_len = p1 - p0, s1 - s0
                if tag2 == 'equal':
                    # Guard against 1-char rasm coincidence across distant lines
                    if sn == 1 and owner and abs(a2 - a1 - (b2 - b1)) > 15:
                        continue
                    extra_matched += sn
                    for k in range(sm_len):
                        pdf_of[s0 + k] = p0 + k
                        exact[s0 + k] = True
                elif tag2 == 'replace' and sn > 0 and sm_len > 0:
                    same_vicinity = True
                    if owner and p1 <= len(owner):
                        same_vicinity = abs(owner[p1 - 1].line - owner[p0].line) <= 1
                    if same_vicinity and sn <= 2 * sm_len + 4 and sm_len <= 2 * sn + 4 and abs(sn - sm_len) <= 10:
                        for k in range(sm_len):
                            pdf_of[s0 + k] = p0 + (k if sn == sm_len else k * sn // sm_len)
    return extra_matched


def align(pdf: DecodedPage, src: SourceSkeleton, refine: bool = True) -> PageAlignment:
    sm = difflib.SequenceMatcher(None, pdf.skel, src.skel, autojunk=False)
    ops = sm.get_opcodes()
    if refine:
        ops = _clean_spurious_equals(ops, pdf.owner)
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
            if refine:
                matched += _align_replace_block(
                    pdf.skel, src.skel, pdf.owner, i1, i2, j1, j2, pdf_of, exact)
            else:
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
                elif 0 < len(glyphs) and len(want) == len(glyphs) + 1:
                    # More source letters than glyphs: some glyphs here are
                    # ligatures (one glyph drawing two or more letters, Lam-
                    # Alef the usual case). Split the letters across the
                    # glyphs as evenly as the counts allow and vote each
                    # glyph for its share; repeated, consistent votes (not
                    # a one-off bad split) are what wins in the end.
                    base, extra = divmod(len(want), len(glyphs))
                    pos = 0
                    for idx, g in enumerate(glyphs):
                        size = base + (1 if idx < extra else 0)
                        self.add(g, want[pos:pos + size])
                        pos += size

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
            if (not dec.resolved(g) or skeleton(current) != best) and k not in out:
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


def _same_line(a, b) -> bool:
    return min(a[3], b[3]) - max(a[1], b[1]) >= 0.5 * min(a[3] - a[1], b[3] - b[1])


def fill_gaps(words: list[str], rects: list) -> list:
    """Places words the alignment left without a box, from their placed
    neighbours: between two neighbours on one line, in the space between
    them; across a line break, on an intermediate missed line when vertical
    space exists, or at the end of the first line / start of the next
    (whichever has the room). Words with no skeleton (such as decorative
    asterisks '*') stay unplaced."""
    placed = [r for r in rects if r]
    if not placed:
        return rects
    col_left = min(r[0] for r in placed)
    col_right = max(r[2] for r in placed)
    letters = sum(max(1, len(skeleton(w))) for w, r in zip(words, rects) if r)
    char_w = sum(r[2] - r[0] for r in placed) / max(letters, 1)
    out = list(rects)
    i = 0
    n = len(out)
    while i < n:
        if out[i] is not None:
            i += 1
            continue
        j = i
        while j < n and out[j] is None:
            j += 1
        real_idx = [k for k in range(i, j) if skeleton(words[k])]
        if not real_idx:
            i = j
            continue
        prev = out[i - 1] if i > 0 else None
        nxt = out[j] if j < n else None
        run = [words[k] for k in real_idx]
        need = char_w * sum(max(1, len(skeleton(w))) for w in run) + char_w * (len(run) - 1)
        span = None  # (x0, x1, y0, y1, rtl)
        if prev and nxt and _same_line(prev, nxt):
            rtl = prev[0] >= nxt[0]
            x0, x1 = (nxt[2], prev[0]) if rtl else (prev[2], nxt[0])
            y0, y1 = min(prev[1], nxt[1]), max(prev[3], nxt[3])
            if x1 - x0 > char_w * 0.5:
                span = (x0, x1, y0, y1, rtl)
            else:
                # No room: the print joins them to a neighbour ("وَ لَمْ" is
                # printed "ولم"). A narrow box on the boundary still puts
                # the word in its place in the reading order.
                mid = (x0 + x1) / 2
                half = max(char_w, need * 0.5) / 2
                span = (mid - half, mid + half, y0, y1, rtl)
        elif prev and nxt:
            rtl = any(unicodedata.bidirectional(c) in ('R', 'AL')
                      for w in words[max(i - 1, 0):j + 1] for c in w)
            line_h = max(10.0, min(prev[3] - prev[1], nxt[3] - nxt[1]))
            v_gap = nxt[1] - prev[3]
            col_w = max(1.0, col_right - col_left)
            prev_indented = ((col_right - prev[2]) > 0.12 * col_w) if rtl else ((prev[0] - col_left) > 0.12 * col_w)
            end_room = (prev[0] - col_left) if rtl else (col_right - prev[2])
            start_room = (col_right - nxt[2]) if rtl else (nxt[0] - col_left)
            if v_gap >= 1.15 * line_h and (prev_indented or need >= 0.45 * col_w or len(run) >= 4):
                # An intermediate line was missed vertically between prev and nxt.
                mid_y = 0.5 * (prev[3] + nxt[1])
                y0, y1 = mid_y - 0.5 * line_h, mid_y + 0.5 * line_h
                w = min(col_w, max(need, char_w * len(run)))
                if prev_indented and w < 0.75 * col_w:
                    cx = 0.5 * (col_left + col_right)
                    x0, x1 = cx - 0.5 * w, cx + 0.5 * w
                else:
                    x0, x1 = (col_right - w, col_right) if rtl else (col_left, col_left + w)
                span = (x0, x1, y0, y1, rtl)
            elif end_room >= 0.6 * need:
                w = min(end_room, need)
                x0, x1 = ((prev[0] - w, prev[0]) if rtl else (prev[2], prev[2] + w))
                span = (x0, x1, prev[1], prev[3], rtl)
            elif start_room >= 0.6 * need:
                w = min(start_room, need)
                x0, x1 = ((nxt[2], nxt[2] + w) if rtl else (nxt[0] - w, nxt[0]))
                span = (x0, x1, nxt[1], nxt[3], rtl)
            else:
                # Neither line has room: just past the end of the first one.
                w = max(char_w, need * 0.5)
                x0, x1 = ((prev[0] - w, prev[0]) if rtl else (prev[2], prev[2] + w))
                span = (x0, x1, prev[1], prev[3], rtl)
        elif prev and not nxt:
            rtl = any(unicodedata.bidirectional(c) in ('R', 'AL')
                      for w in words[max(i - 1, 0):j] for c in w)
            end_room = (prev[0] - col_left) if rtl else (col_right - prev[2])
            if end_room >= char_w:
                w = min(end_room, need)
                x0, x1 = ((prev[0] - w, prev[0]) if rtl else (prev[2], prev[2] + w))
                span = (x0, x1, prev[1], prev[3], rtl)
        if span:
            x0, x1, y0, y1, rtl = span
            # Never outside the text column (nor so thin it says nothing).
            x0, x1 = max(x0, col_left), min(x1, col_right)
            if x1 - x0 < 0.3 * char_w:
                mid = min(max((x0 + x1) / 2, col_left + char_w / 2), col_right - char_w / 2)
                x0, x1 = mid - char_w / 2, mid + char_w / 2
            weights = [max(1, len(skeleton(w))) for w in run]
            total = sum(weights)
            pos = x1 if rtl else x0
            for idx, wt in zip(real_idx, weights):
                width = (x1 - x0) * wt / total
                out[idx] = (pos - width, y0, pos, y1) if rtl else (pos, y0, pos + width, y1)
                pos = pos - width if rtl else pos + width
        i = j
    return out


@dataclass
class WordBox:
    rect: tuple[float, float, float, float] | None
    exact: float  # share of the word's letters matched exactly


def _filter_horizontal_cluster(glyphs: list[Glyph]) -> list[Glyph]:
    """Splits a single line's matched glyphs for one word if a wide horizontal
    gap separates them (e.g. across a poetry hemistich gap or into another
    word), returning the dominant contiguous cluster."""
    if len(glyphs) <= 1:
        return glyphs
    by_x = sorted(glyphs, key=lambda g: 0.5 * (g.bbox[0] + g.bbox[2]))
    h = max(8.0, sum(g.bbox[3] - g.bbox[1] for g in by_x) / len(by_x))
    max_gap = max(1.6 * h, 16.0)
    clusters: list[list[Glyph]] = [[by_x[0]]]
    for g in by_x[1:]:
        prev_x1 = max(x.bbox[2] for x in clusters[-1])
        if g.bbox[0] - prev_x1 > max_gap:
            clusters.append([g])
        else:
            clusters[-1].append(g)
    if len(clusters) == 1:
        return glyphs
    return max(clusters, key=lambda cl: (len(cl), sum(x.bbox[2] - x.bbox[0] for x in cl)))


def word_boxes(pdf: DecodedPage, src: SourceSkeleton, al: PageAlignment) -> list[WordBox]:
    per_word: list[list[int]] = [[] for _ in src.words]
    for j, wi in enumerate(src.word_of):
        per_word[wi].append(j)
    out: list[WordBox] = []
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
        best = _filter_horizontal_cluster(best)
        x0 = min(g.bbox[0] for g in best)
        y0 = min(g.bbox[1] for g in best)
        x1 = max(g.bbox[2] for g in best)
        y1 = max(g.bbox[3] for g in best)
        for g in best:
            for m in g.marks:  # marks may stick out above or below
                y0 = min(y0, m.bbox[1])
                y1 = max(y1, m.bbox[3])
        out.append(WordBox((x0, y0, x1, y1), exact))

    # Guard against single-word vertical teleports (e.g. the final word of a
    # poem matching a 2-letter substring 140pt lower inside a footnote).
    heights = sorted(wb.rect[3] - wb.rect[1] for wb in out if wb.rect is not None)
    if heights:
        med_h = max(10.0, heights[len(heights) // 2])
        n = len(out)
        for wi, wb in enumerate(out):
            if wb.rect is None:
                continue
            cy = 0.5 * (wb.rect[1] + wb.rect[3])
            prev_y = next_y = None
            for p in range(wi - 1, max(-1, wi - 5), -1):
                if out[p].rect is not None:
                    prev_y = 0.5 * (out[p].rect[1] + out[p].rect[3])
                    break
            for q in range(wi + 1, min(n, wi + 5)):
                if out[q].rect is not None:
                    next_y = 0.5 * (out[q].rect[1] + out[q].rect[3])
                    break
            if prev_y is not None and next_y is not None:
                if abs(prev_y - next_y) <= 1.8 * med_h and min(abs(cy - prev_y), abs(cy - next_y)) > 2.5 * med_h:
                    out[wi] = WordBox(None, 0.0)
            elif (prev_y is not None or next_y is not None) and (wb.exact < 0.8 or len(per_word[wi]) <= 4):
                ref_y = prev_y if prev_y is not None else next_y
                if abs(cy - ref_y) > 3.0 * med_h:
                    out[wi] = WordBox(None, 0.0)
    return out
