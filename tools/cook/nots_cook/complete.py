"""Making a book complete: what the PDF shows and the text does not have.

The source text is the best text there is, but it may not hold everything
on the pages: a front matter, indexes, footnotes, a heading, a lost
paragraph. Each page's content (its glyphs, or what OCR read) is compared
with the source; whatever has no counterpart there is written into the
book, in its place on the page. Pages the source does not cover at all take
their whole text from the PDF.

Running headers, footers and page numbers are page furniture, not text of
the book, and are left out.
"""

from __future__ import annotations

import collections
try:  # the same algorithm compiled: identical results, ~11x faster
    import cydifflib as difflib
except ImportError:
    import difflib
import itertools
import re
from dataclasses import dataclass, field

from .align import DecodedPage, PageAlignment, SourceSkeleton, WordBox, keep
from .engines import FOLD, OcrWord, letters, split_tail
from .fonts import MIRROR
from .glyphs import Glyph, text_dir

MIN_LETTERS = 5     # less than this missing is a misreading, not a lost text
ANCHOR = 4          # letters in a row that really tie the two sides together
SOURCE_SHARE = 0.4  # a gap with more source letters than this is a misreading


@dataclass(eq=False)
class Unit:
    """One word on the page, as the PDF side has it."""
    text: str
    box: tuple[float, float, float, float]
    line: int
    i0: int = -1      # its letters in the page skeleton: [i0, i1)
    i1: int = -1
    conf: float = -1.0
    both: bool = False
    origin: str = 'ocr'   # 'ocr' or 'glyph'

    @property
    def size(self) -> int:
        return max(self.i1 - self.i0, 0)


def letter_page(words: list[OcrWord]) -> tuple[DecodedPage, list[Unit]]:
    """OCR words as a "decoded page" of letters, one pseudo-glyph per
    letter with its share of the word's box (right to left for Arabic).
    The source and the print often split words differently (the source
    writes "وَ كَانَتْ", the print "وكانت"); with letters, every source word
    still gets its own part of the printed word."""
    dec = DecodedPage()
    chars: list[str] = []
    units: list[Unit] = []
    seq = 0
    for w in words:
        x0, y0, x1, y1 = w.box
        kept = [c for c in w.text if keep(c)]
        u = Unit(w.text, w.box, w.line, seq, seq + len(kept), w.conf, w.both)
        units.append(u)
        if not kept:
            u.i0 = u.i1 = -1
            continue
        rtl = text_dir(w.text) == 'R'
        cw = (x1 - x0) / len(kept)
        for k, c in enumerate(kept):
            lx0 = x1 - (k + 1) * cw if rtl else x0 + k * cw
            g = Glyph(seq=seq, font='ocr', gid=-1, tu=c, x=lx0, y=y1,
                      bbox=(lx0, y0, lx0 + cw, y1), size=y1 - y0)
            g.text = c
            g.line = w.line
            seq += 1
            chars.append(c)
            dec.owner.append(g)
    dec.skel = ''.join(chars)
    return dec, units


ROUGH_FLOOR = 0.33   # below this, a page's reading and its text are two pages (unrelated Arabic texts give 0.15-0.3)


def rough_boxes(units: list[Unit], src: SourceSkeleton) -> list[WordBox]:
    """A box for every word of [src] on a page whose reading is too rough to
    pin the words one by one (al-Mu'jam's pages of numbered references,
    "الكافي: ج٣، ك٣، ب٧٥، ح٣"): each engine misreads the digits, the two texts
    share only 40% of their letters, and no word is placed. The page is this
    page all the same, so the words are spread along the lines the engines
    read, by letters: each lands on the right line, within a few words of its
    place on it. The boxes say so: exact is 0."""
    lines = [ln for ln in _lines(units) if sum(u.size for u in ln)]
    if not lines or not src.words:
        return [WordBox(None, 0.0) for _ in src.words]
    sizes = [sum(u.size for u in ln) for ln in lines]
    total_ocr = sum(sizes)
    per_word = [0] * len(src.words)
    for wi in src.word_of:
        per_word[wi] += 1
    total_src = sum(per_word) or 1
    out: list[WordBox] = []
    li, start, done = 0, 0, 0
    for n_letters in per_word:
        if not n_letters:
            out.append(WordBox(None, 0.0))
            continue
        a, b = done / total_src * total_ocr, (done + n_letters) / total_src * total_ocr
        done += n_letters
        while li < len(lines) - 1 and start + sizes[li] < (a + b) / 2:
            start += sizes[li]
            li += 1
        ln = lines[li]
        x0, x1 = min(u.box[0] for u in ln), max(u.box[2] for u in ln)
        y0, y1 = min(u.box[1] for u in ln), max(u.box[3] for u in ln)
        fa = min(max((a - start) / sizes[li], 0.0), 1.0)
        fb = min(max((b - start) / sizes[li], fa), 1.0)
        if fb - fa < 0.5 / sizes[li]:
            fb = min(1.0, fa + 0.5 / sizes[li])
        ltr = len(ln) > 1 and ln[0].box[0] < ln[-1].box[0]
        w = x1 - x0
        rect = (x0 + fa * w, y0, x0 + fb * w, y1) if ltr else (x1 - fb * w, y0, x1 - fa * w, y1)
        out.append(WordBox(rect, 0.0))
    return out


def glyph_units(dp: DecodedPage) -> list[Unit]:
    """The words of a page's decoded glyphs, in reading order."""
    where: dict[int, list[int]] = {}
    for i, g in enumerate(dp.owner):
        where.setdefault(id(g), [i, i + 1])[1] = i + 1
    out: list[Unit] = []
    for li, line in enumerate(dp.lines):
        cur: list[tuple[Glyph, str]] = []

        def flush():
            spots = [where[id(g)] for g, _ in cur if id(g) in where]
            if spots:
                gs = [g for g, _ in cur]
                out.append(Unit(''.join(t for _, t in cur),
                                (min(g.bbox[0] for g in gs), min(g.bbox[1] for g in gs),
                                 max(g.bbox[2] for g in gs), max(g.bbox[3] for g in gs)),
                                li, min(s[0] for s in spots), max(s[1] for s in spots), origin='glyph'))
            cur.clear()

        for g, rtl in line:
            t = MIRROR.get(g.text, g.text) if rtl else g.text
            if not t or t.isspace():
                flush()
                continue
            cur.append((g, t + ''.join(m.text for m in g.marks)))
        flush()
    return out


def _lines(units: list[Unit]) -> list[list[Unit]]:
    out: list[list[Unit]] = []
    for u in units:
        if out and out[-1][-1].line == u.line:
            out[-1].append(u)
        else:
            out.append([u])
    return out


def _mid(line: list[Unit]) -> float:
    return sum((u.box[1] + u.box[3]) / 2 for u in line) / len(line)


def _by_height(units: list[Unit]) -> list[list[Unit]]:
    return sorted(_lines(units), key=_mid)


EDGE = 0.14  # top and bottom share of the page where headers and footers live


def _edges(units: list[Unit], height: float) -> list[list[Unit]]:
    lines = _by_height(units)
    if not lines:
        return []
    out = []
    if _mid(lines[0]) < EDGE * height:
        out.append(lines[0])
    if len(lines) > 1 and _mid(lines[-1]) > (1 - EDGE) * height:
        out.append(lines[-1])
    return out


def edge_words(pages: list[list[Unit]], height: float) -> collections.Counter:
    """On how many pages each word sits on a page's first or last line."""
    seen: collections.Counter = collections.Counter()
    for units in pages:
        words = {letters(u.text) for line in _edges(units, height) for u in line}
        seen.update(w for w in words if len(w) >= 3)
    return seen


def furniture_lines(units: list[Unit], repeated: collections.Counter, height: float) -> set[int]:
    """Ids of the page's lines that are its running header, footer or page
    number: an edge line that is only a number, or whose words keep coming
    back on the edges of other pages. Position alone would not do: the last
    line of a footnote also ends every page at the same height."""
    out: set[int] = set()
    for line in _edges(units, height):
        words = [letters(u.text) for u in line]
        total = sum(len(w) for w in words)
        again = sum(len(w) for w in words if repeated[w] >= 3)
        if total == 0 or again >= 0.5 * total:
            out.add(line[0].line)
    return out


_NOISE = re.compile(r'^[\W_]+$')
_LATIN_SPECK = re.compile(r'[.\W]*[A-Za-zÀ-ÿ]{1,4}[.\W]*')


def clean_words(units: list[Unit]) -> list[Unit]:
    """Without stray marks of dirt read as symbols."""
    out = []
    for u in units:
        t = u.text.strip('|_~*^`\'"\\')
        if not t or (_NOISE.fullmatch(t) and not any(c.isdigit() for c in t) and len(t) > 2):
            continue
        if not letters(t) and not any(c.isdigit() for c in t) and t not in ('،', '؛', '.', ':', '؟', '-', '(', ')', '[', ']'):
            continue
        if out and not letters(t) and not any(c.isdigit() for c in t) and out[-1].text.endswith(t):
            continue
        if not u.both and _LATIN_SPECK.fullmatch(t):  # numbers in small print, read as Latin
            continue
        out.append(u if t == u.text else Unit(t, u.box, u.line, u.i0, u.i1, u.conf, u.both, u.origin))
    return out


_DIGITS = '٠١٢٣٤٥٦٧٨٩'
_NOTE = re.compile(r'^\(?([٠-٩]{1,2})\)?$')


def numbered_notes(units: list[Unit]) -> list[Unit]:
    """Footnotes count up, so the number of a line that breaks the count
    was misread: small numbers in brackets are the hardest thing on a page."""
    firsts = [line[0] for line in _lines(units)]
    marked = [u for u in firsts if _NOTE.match(u.text)]
    if len(marked) < 3:
        return units
    expected = None
    wrong = 0
    fixed: dict[int, str] = {}
    for u in marked:
        n = int(_NOTE.match(u.text).group(1).translate(str.maketrans(_DIGITS, '0123456789')))
        if expected is not None and n != expected:
            n = expected
            wrong += 1
        fixed[id(u)] = '(' + str(n).translate(str.maketrans('0123456789', _DIGITS)) + ')'
        expected = n + 1
    if wrong > len(marked) / 3:  # these do not count: an index's numbers, say
        return units
    return [Unit(fixed[id(u)], u.box, u.line, u.i0, u.i1, u.conf, u.both, u.origin) if id(u) in fixed else u
            for u in units]


def believable(units: list[Unit], lexicon) -> bool:
    """Whether a stretch read from the page is text rather than an ornament
    or dirt: most of its letters in words the book knows, words two engines
    agree on, or words the engine is sure of."""
    total = good = 0
    for u in units:
        l = letters(u.text)
        total += len(l)
        if len(l) >= 2 and (u.both or l in lexicon or u.conf >= 75):
            good += len(l)
    return total >= 2 and good >= 0.5 * total


def plainly_text(line: list[Unit], lexicon) -> bool:
    """A line of a page that is mostly a photo: its caption, not what the
    engines made of the photo."""
    total = sum(len(letters(u.text)) for u in line)
    good = sum(len(letters(u.text)) for u in line if len(letters(u.text)) >= 2
               and (u.both or letters(u.text) in lexicon))
    return good >= 0.7 * total


def believable_line(line: list[Unit], lexicon) -> bool:
    """Whether a line read on a page the source does not cover is text. A
    photo of a manuscript or an ornament also yields letters, but seldom
    two real words: a short line needs them, or one sure long word."""
    good = [letters(u.text) for u in line
            if len(letters(u.text)) >= 3 and (u.both or letters(u.text) in lexicon or u.conf >= 75)]
    if not good:
        return not any(letters(u.text) for u in line) and any(c.isdigit() for u in line for c in u.text)
    total = sum(len(letters(u.text)) for u in line)
    if sum(len(w) for w in good) < 0.5 * total:
        return False
    return len(good) >= 2 or (len(good[0]) >= 4 and any(u.both for u in line))


def wordy(line: list[Unit]) -> bool:
    return sum(1 for u in line if len(letters(u.text)) >= 3) >= 2


def without_specks(line: list[Unit], lexicon) -> list[Unit]:
    """A row without what only one engine saw in its blanks: a number or a
    speck read as letters, far from any word, unknown to the book."""
    out = []
    for k, u in enumerate(line):
        l = letters(u.text)
        if l and not u.both and l not in lexicon and 0 <= u.conf < 60:
            room = 2 * (u.box[3] - u.box[1])
            after = u.box[0] - line[k + 1].box[2] if k + 1 < len(line) else room + 1
            before = line[k - 1].box[0] - u.box[2] if k else room + 1
            if min(after, before) > room:
                continue
        out.append(u)
    return out


def known_share(units: list[Unit], lexicon) -> float:
    total = good = 0
    for u in units:
        l = letters(u.text)
        total += len(l)
        good += len(l) if l in lexicon else 0
    return good / total if total else 0.0


@dataclass
class Gap:
    """A stretch of the page the source has nothing (or too little) for."""
    units: list[Unit]
    pos: int              # source word to insert before (len(words): at the end)
    source_letters: int
    whole_lines: bool


def _already_there(text: str, skel: str) -> bool:
    """Whether the page's text has this passage after all, somewhere the
    alignment did not tie it to."""
    fold = lambda t: t.translate(FOLD)
    sm = difflib.SequenceMatcher(None, fold(text), fold(skel), autojunk=False)
    m = sum(b.size for b in sm.get_matching_blocks() if b.size >= ANCHOR)
    return m >= 0.6 * len(text)


def gaps(units: list[Unit], al: PageAlignment, pdf_skel: str, src: SourceSkeleton,
         furniture: set[int]) -> list[Gap]:
    """Stretches of the page between firm matches with far more on the PDF
    side than on the source side."""
    anchors = [op for op in al.ops if op[0] == 'equal' and op[2] - op[1] >= ANCHOR]
    spans = []
    pi = pj = 0
    for _, i1, i2, j1, j2 in anchors:
        spans.append((pi, i1, pj, j1))
        pi, pj = i2, j2
    spans.append((pi, len(pdf_skel), pj, len(src.skel)))
    out: list[Gap] = []
    for ia, ib, ja, jb in spans:
        if ib - ia < MIN_LETTERS:
            continue
        inside = [u for u in units if u.size and u.line not in furniture
                  and min(u.i1, ib) - max(u.i0, ia) >= 0.6 * u.size]
        n = sum(u.size for u in inside)
        if n < MIN_LETTERS or jb - ja > SOURCE_SHARE * n:
            continue
        at = units.index(inside[0])
        if at and units[at - 1].line == inside[0].line:
            head = [u for u in inside if u.line == inside[0].line]
            if len(head) < len(inside) and sum(u.size for u in head) < MIN_LETTERS + 2:
                inside = inside[len(head):]
        if _already_there(''.join(c for u in inside for c in pdf_skel[u.i0:u.i1]), src.skel):
            continue
        if jb < len(src.skel):
            w = src.word_of[jb]
            pos = w + 1 if jb > 0 and src.word_of[jb - 1] == w else w
        else:
            pos = len(src.words)
        first, last = inside[0], inside[-1]
        at = units.index(first)
        to = units.index(last)
        starts = at == 0 or units[at - 1].line != first.line
        ends = to == len(units) - 1 or units[to + 1].line != last.line
        out.append(Gap(inside, pos, jb - ja, starts and ends))
    return out


@dataclass
class Phrases:
    """The book's stock phrases in brackets, "(عليه السلام)" and the like,
    which print small and OCR misreads."""
    table: dict[str, str]                     # letters -> the phrase
    after: dict[str, collections.Counter]     # a word -> the phrases that follow it

    def __bool__(self):
        return bool(self.table)

    def expected(self, word: str) -> str | None:
        """The phrase the book keeps writing after [word]."""
        best = self.after.get(letters(word), collections.Counter()).most_common(1)
        return best[0][0] if best and best[0][1] >= 5 else None


def phrase_table(pages: list[str], least: int = 5) -> Phrases:
    seen: collections.Counter = collections.Counter()
    after: dict[str, collections.Counter] = {}
    for text in pages:
        for before, phrase in re.findall(r'(\S+)?\s*\(([^()\n]{3,40})\)', text):
            phrase = phrase.strip()
            seen[phrase] += 1
            if before:
                after.setdefault(letters(before), collections.Counter())[phrase] += 1
    table: dict[str, str] = {}
    for phrase, n in seen.most_common():
        key = letters(phrase)
        if n >= least and len(key) >= 5 and key not in table:
            table[key] = phrase
    known = set(table.values())
    return Phrases(table, {w: collections.Counter({p: n for p, n in c.items() if p in known})
                           for w, c in after.items()})


SURE = 0.85      # a reading this close is the phrase, wherever it stands
LIKELY = 0.6     # this close, only for the phrase the word before calls for


def fix_phrases(words: list[tuple[str, tuple]], table: Phrases) -> list[tuple[str, tuple]]:
    """Replaces a misread stock phrase by the book's own spelling of it.
    These are blessings and the like: a wrong one is far worse than a
    garbled one, so a loose match needs the word before to call for it."""
    if not table:
        return words
    out: list[tuple[str, tuple]] = []
    i = 0
    while i < len(words):
        w = words[i][0]
        best = None
        expected = table.expected(out[-1][0]) if out else None
        # The opening bracket, in small print, often reads as a "ر".
        if w.startswith('(') or (expected and w.startswith('ر')):
            for n in range(1, 6):
                part = words[i:i + n]
                got = letters(''.join(x for x, _ in part))
                if not w.startswith('('):
                    got = got[1:]
                if len(part) < n or not got:
                    break
                for key, phrase in table.table.items():
                    if 0.6 * len(key) <= len(got) <= 1.4 * len(key):
                        r = difflib.SequenceMatcher(None, got, key, autojunk=False).ratio()
                        if best is None or r > best[0]:
                            best = (r, n, phrase)
            # The closest phrase or none: never a likely one over a closer one.
            if best and best[0] < (LIKELY if best[2] == expected else SURE):
                best = None
        if best is None:
            out.append(words[i])
            i += 1
            continue
        _, n, phrase = best
        part = words[i:i + n]
        tail = re.sub(r'[()«»\[\]]', '', split_tail(part[-1][0])[1])
        x0 = min(b[0] for _, b in part)
        x1 = max(b[2] for _, b in part)
        y0 = min(b[1] for _, b in part)
        y1 = max(b[3] for _, b in part)
        new = ('(' + phrase + ')' + tail).split()
        total = sum(len(t) for t in new)
        pos = x1
        for t in new:
            width = (x1 - x0) * len(t) / total
            out.append((t, (pos - width, y0, pos, y1)))
            pos -= width
        i += n
    return out


@dataclass
class FinalPage:
    """A page's words in their final order."""
    words: list[str] = field(default_factory=list)
    boxes: list = field(default_factory=list)
    breaks: list[bool] = field(default_factory=list)   # a new paragraph starts at this word
    added: list[bool] = field(default_factory=list)    # came from the PDF, not the source text
    source_at: list[int] = field(default_factory=list)  # final index of each source word

    @property
    def text(self) -> str:
        out: list[str] = []
        for i, w in enumerate(self.words):
            if i:
                out.append('\n' if self.breaks[i] else ' ')
            out.append(w)
        return ''.join(out)

    def added_ranges(self) -> list[list[int]]:
        out: list[list[int]] = []
        for i, a in enumerate(self.added):
            if a:
                if out and out[-1][1] == i - 1:
                    out[-1][1] = i
                else:
                    out.append([i, i])
        return out


def source_page(text: str, boxes: list) -> FinalPage:
    f = FinalPage()
    k = 0
    for para in text.split('\n'):
        for i, w in enumerate(para.split()):
            f.words.append(w)
            f.boxes.append(boxes[k] if k < len(boxes) else None)
            f.breaks.append(i == 0 and k > 0)
            f.added.append(False)
            f.source_at.append(k)
            k += 1
    return f


def region(units: list[Unit]) -> tuple[float, float, float, float]:
    """The box around some words."""
    return (min(u.box[0] for u in units), min(u.box[1] for u in units),
            max(u.box[2] for u in units), max(u.box[3] for u in units))


def insert(f: FinalPage, gaps_: list[Gap], phrases: dict[str, str], polish=None) -> list[str]:
    """Writes [gaps_] into the page; returns the texts added. [polish] may
    give a better reading of a passage's words."""
    texts = []
    for gap in sorted(gaps_, key=lambda g: g.pos, reverse=True):
        units = clean_words(gap.units)
        if units and units[0].origin == 'ocr':
            units = numbered_notes(units)
        words = [(w, u.box) for u in units for w in u.text.split()]
        better = polish(words, units) if polish and units and units[0].origin == 'ocr' else None
        words = fix_phrases(better or words, phrases)
        if not words:
            continue
        at = f.source_at[gap.pos] if gap.pos < len(f.source_at) else len(f.words)
        n = len(words)
        f.words[at:at] = [w for w, _ in words]
        f.boxes[at:at] = [b for _, b in words]
        f.breaks[at:at] = [gap.whole_lines and k == 0 and at > 0 for k in range(n)]
        f.added[at:at] = [True] * n
        if gap.whole_lines and at + n < len(f.words):
            f.breaks[at + n] = True
        f.source_at = [i + n if i >= at else i for i in f.source_at]
        texts.append(' '.join(w for w, _ in words))
    return texts[::-1]


def page_from_pdf(units: list[Unit], furniture: set[int], lexicon, phrases: dict[str, str],
                  trusted: bool = False, polish=None) -> FinalPage:
    """A page the source does not cover: its text, line by line, minus its
    furniture and anything that reads like an ornament rather than text."""
    f = FinalPage()
    lines = [clean_words(line) for line in _lines(units) if line[0].line not in furniture]
    if not trusted:
        lines = [without_specks(line, lexicon) for line in lines]
    lines = [line for line in lines if line]
    if not trusted and lines:
        numbered = numbered_notes([u for line in lines for u in line])
        lines = [list(g) for _, g in itertools.groupby(numbered, key=lambda u: u.line)]
    if not trusted:
        # On a page of text, a line an engine read badly is still a line of
        # it; on a photo, only what reads as text is.
        sure = [line for line in lines if believable_line(line, lexicon)]
        worded = [line for line in lines if any(letters(u.text) for u in line)]
        page_of_text = 2 * sum(1 for line in sure if any(letters(u.text) for u in line)) >= len(worded)
        if page_of_text:
            lines = [line for line in lines if any(line is s for s in sure) or wordy(line)]
        else:
            lines = [line for line in sure if plainly_text(line, lexicon)]
    # Numbers alone belong to a page of text (an index's columns), not to a
    # photo where specks read as digits.
    if sum(1 for line in lines if any(letters(u.text) for u in line)) < 3:
        lines = [line for line in lines if any(letters(u.text) for u in line)]
    for line in lines:
        words = [(w, u.box) for u in line for w in u.text.split()]
        better = polish(words, line) if polish and not trusted else None
        words = fix_phrases(better or words, phrases)
        for k, (w, b) in enumerate(words):
            f.words.append(w)
            f.boxes.append(b)
            f.breaks.append(k == 0 and len(f.words) > 1)
            f.added.append(True)
    return f
