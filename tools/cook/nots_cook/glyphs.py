"""The glyphs of a page, grouped into lines and put in reading order.

PDFs made by Word draw right-to-left text in visual order (left to right on
the page). To compare the page with the source text we need logical order:
each line reversed, except runs of digits and Latin text, which keep their
left-to-right order. Diacritics are their own glyphs; each one belongs to
the letter drawn just before it.
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass, field

import pymupdf

from .fonts import MIRROR, family_key


@dataclass(eq=False)
class Glyph:
    seq: int                 # order of drawing on the page
    font: str                # font name without subset tag
    gid: int
    tu: str                  # text per the PDF's own /ToUnicode
    x: float                 # origin (baseline start), points, top-left page origin
    y: float
    bbox: tuple[float, float, float, float]
    size: float
    text: str = ''           # decoded text (set by the decoder)
    line: int = -1
    marks: list['Glyph'] = field(default_factory=list)  # diacritics on this glyph


def is_mark(s: str) -> bool:
    return bool(s) and all(unicodedata.category(c) in ('Mn', 'Me') for c in s)


def char_dir(c: str) -> str:
    b = unicodedata.bidirectional(c)
    if b in ('R', 'AL'):
        return 'R'
    if b == 'L':
        return 'L'
    if b in ('EN', 'AN'):
        return 'N'  # number
    return ''


def text_dir(s: str) -> str:
    for c in s:
        d = char_dir(c)
        if d:
            return d
    return ''


def page_glyphs(page: pymupdf.Page) -> list[Glyph]:
    """Every glyph drawn on the page, in drawing order."""
    out: list[Glyph] = []
    seq = 0
    for span in page.get_texttrace():
        if span.get('type') == 3 and span.get('opacity', 1) == 0:
            pass  # invisible text is still text (e.g. an OCR layer)
        font = family_key(span.get('font', ''))
        size = float(span.get('size', 0))
        chars = span['chars']
        for k, c in enumerate(chars):
            if c[1] < 0:
                continue  # continuation of the previous glyph's text
            tu = chr(c[0]) if c[0] > 0 else ''
            j = k + 1
            while j < len(chars) and chars[j][1] < 0:
                if chars[j][0] > 0:
                    tu += chr(chars[j][0])
                j += 1
            ox, oy = c[2]
            out.append(Glyph(seq=seq, font=font, gid=c[1], tu=tu, x=ox, y=oy,
                             bbox=tuple(c[3]), size=size))
            seq += 1
    return out


def attach_marks(glyphs: list[Glyph]) -> list[Glyph]:
    """Moves each diacritic onto the glyph drawn before it; returns the base
    glyphs (letters, digits, spaces, punctuation)."""
    bases: list[Glyph] = []
    for g in glyphs:
        if is_mark(g.text) and bases and abs(bases[-1].y - g.y) < max(g.size, 1):
            bases[-1].marks.append(g)
        else:
            bases.append(g)
    return bases


def group_lines(bases: list[Glyph]) -> list[list[Glyph]]:
    """Glyphs sharing a baseline, top to bottom."""
    lines: list[dict] = []
    for g in bases:
        tol = max(g.size * 0.3, 1.5)
        for L in lines:
            if abs(L['y'] - g.y) <= tol:
                L['g'].append(g)
                break
        else:
            lines.append({'y': g.y, 'g': [g]})
    lines.sort(key=lambda L: L['y'])
    out = []
    for i, L in enumerate(lines):
        for g in L['g']:
            g.line = i
            for m in g.marks:
                m.line = i
        out.append(L['g'])
    return out


def logical_order(line: list[Glyph]) -> list[tuple[Glyph, bool]]:
    """One line's base glyphs in reading order, each with True when it sits
    in right-to-left text (where brackets are drawn mirrored)."""
    vis = sorted(line, key=lambda g: (g.x, g.seq))
    dirs = [text_dir(g.text) for g in vis]
    if 'R' not in dirs:
        return [(g, False) for g in vis]
    rev = vis[::-1]
    rdirs = dirs[::-1]
    out: list[tuple[Glyph, bool]] = []
    i = 0
    n = len(rev)
    while i < n:
        d = rdirs[i]
        if d in ('L', 'N'):
            # A left-to-right run: numbers (with their separators) or Latin
            # words (with the spaces between them).
            j = i + 1
            while j < n:
                if rdirs[j] in ('L', 'N'):
                    j += 1
                    continue
                t = rev[j].text
                if j + 1 < n and rdirs[j + 1] in ('L', 'N') and (
                        (t and t in '.,:/-+%٫٬') or (t.isspace() and d == 'L' and rdirs[j + 1] == 'L')):
                    j += 1
                    continue
                break
            out.extend((g, False) for g in rev[i:j][::-1])
            i = j
        else:
            out.append((rev[i], True))
            i += 1
    return out


def logical_text(glyph: Glyph, rtl_run: bool) -> str:
    """Text of a glyph and its diacritics in reading order."""
    t = glyph.text
    if rtl_run and t in MIRROR:
        t = MIRROR[t]
    return t + ''.join(m.text for m in glyph.marks)


def page_lines(glyphs: list[Glyph]) -> list[list[tuple[Glyph, bool]]]:
    """Base glyphs (with marks attached) per line, each line in reading order."""
    for g in glyphs:
        g.marks = []
    bases = attach_marks(glyphs)
    return [logical_order(L) for L in group_lines(bases)]
