"""An invisible text layer for pages that have none (scans).

A scanned page is only a picture: nothing on it can be selected or copied,
in the app or in any PDF viewer. This writes the book's text onto such a
page the way OCR tools make a "searchable PDF": every word, from the word
map (the source text, not OCR guesses), sits exactly on its box, drawn in
text render mode 3 (invisible). The page looks exactly as before; viewers
can now select it, copy it and search it.

The font is a tiny one built here: one box-shaped glyph that every
character uses (its shape never shows), character codes that are the
Unicode code points themselves, and a /ToUnicode that says so. So the
text carries no font license and adds almost nothing to the file.

Right-to-left text is written in visual order (left to right on the page,
digits and Latin kept in reading order), which is how viewers expect a PDF
line to be drawn and what they reverse back into reading order.
"""

from __future__ import annotations

import io
import unicodedata

import pymupdf
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

from .fonts import MIRROR

FONT_NAME = 'NotsText'
ADVANCE = 500        # glyph width, 1/1000 em
ASCENT, DESCENT = 800, -200


def _glyphless_ttf() -> bytes:
    def box():
        pen = TTGlyphPen(None)
        pen.moveTo((0, DESCENT))
        pen.lineTo((0, ASCENT))
        pen.lineTo((ADVANCE, ASCENT))
        pen.lineTo((ADVANCE, DESCENT))
        pen.closePath()
        return pen.glyph()

    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(['.notdef', 'box'])
    fb.setupCharacterMap({0x20: 'box'})
    fb.setupGlyf({'.notdef': box(), 'box': box()})
    fb.setupHorizontalMetrics({'.notdef': (ADVANCE, 0), 'box': (ADVANCE, 0)})
    fb.setupHorizontalHeader(ascent=ASCENT, descent=DESCENT)
    fb.setupNameTable({'familyName': FONT_NAME, 'styleName': 'Regular'})
    fb.setupOS2(sTypoAscender=ASCENT, sTypoDescender=DESCENT,
                usWinAscent=ASCENT, usWinDescent=-DESCENT)
    fb.setupPost()
    buf = io.BytesIO()
    fb.save(buf)
    return buf.getvalue()


def _identity_tounicode() -> bytes:
    lines = ['/CIDInit /ProcSet findresource begin', '12 dict begin', 'begincmap',
             '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def',
             '/CMapName /Adobe-Identity-UCS def', '/CMapType 2 def',
             '1 begincodespacerange', '<0000> <FFFF>', 'endcodespacerange']
    ranges = [f'<{hi:02X}00> <{hi:02X}FF> <{hi:02X}00>' for hi in range(256)
              if not 0xD8 <= hi <= 0xDF]  # no lone surrogates
    for k in range(0, len(ranges), 100):
        chunk = ranges[k:k + 100]
        lines.append(f'{len(chunk)} beginbfrange')
        lines += chunk
        lines.append('endbfrange')
    lines += ['endcmap', 'CMapName currentdict /CMap defineresource pop', 'end', 'end']
    return '\n'.join(lines).encode('ascii')


def _new_stream(doc: pymupdf.Document, dict_src: str, data: bytes) -> int:
    x = doc.get_new_xref()
    doc.update_object(x, dict_src)
    doc.update_stream(x, data, compress=True)
    return x


def add_font(doc: pymupdf.Document) -> int:
    """The invisible-text font, as a Type0 font object; returns its xref."""
    ttf = _glyphless_ttf()
    ff = _new_stream(doc, f'<</Length1 {len(ttf)}>>', ttf)
    fd = doc.get_new_xref()
    doc.update_object(fd, (
        f'<</Type/FontDescriptor/FontName/{FONT_NAME}/Flags 4'
        f'/FontBBox[0 {DESCENT} {ADVANCE} {ASCENT}]/ItalicAngle 0'
        f'/Ascent {ASCENT}/Descent {DESCENT}/CapHeight {ASCENT}/StemV 80'
        f'/FontFile2 {ff} 0 R>>'))
    c2g = _new_stream(doc, '<<>>', b'\x00\x01' * 65536)  # every code -> the box glyph
    cid = doc.get_new_xref()
    doc.update_object(cid, (
        f'<</Type/Font/Subtype/CIDFontType2/BaseFont/{FONT_NAME}'
        f'/CIDSystemInfo<</Registry(Adobe)/Ordering(Identity)/Supplement 0>>'
        f'/FontDescriptor {fd} 0 R/DW {ADVANCE}/CIDToGIDMap {c2g} 0 R>>'))
    tu = _new_stream(doc, '<<>>', _identity_tounicode())
    t0 = doc.get_new_xref()
    doc.update_object(t0, (
        f'<</Type/Font/Subtype/Type0/BaseFont/{FONT_NAME}/Encoding/Identity-H'
        f'/DescendantFonts[{cid} 0 R]/ToUnicode {tu} 0 R>>'))
    return t0


def _dir(c: str) -> str:
    b = unicodedata.bidirectional(c)
    if b in ('R', 'AL'):
        return 'R'
    if b == 'L':
        return 'L'
    if b in ('EN', 'AN'):
        return 'N'
    return ''


def _is_mark(c: str) -> bool:
    return unicodedata.category(c) in ('Mn', 'Me')


def _letterish(c: str) -> bool:
    return unicodedata.bidirectional(c) in ('R', 'AL', 'L', 'EN', 'AN')


def _visual_core(word: str) -> str:
    # Letters (each with its diacritics) right to left, digits and Latin
    # left to right; a letter's diacritics are drawn just before it, in
    # reading order, which viewers turn back into letter-then-diacritics.
    clusters: list[list[str]] = []
    for c in word:
        if _is_mark(c) and clusters:
            clusters[-1].append(c)
        else:
            clusters.append([c])
    dirs = [_dir(cl[0]) for cl in clusters]
    if 'R' not in dirs:
        return word
    rev, rdirs = clusters[::-1], dirs[::-1]
    out: list[str] = []
    i = 0
    while i < len(rev):
        if rdirs[i] in ('L', 'N'):
            j = i + 1
            while j < len(rev) and (rdirs[j] in ('L', 'N') or (
                    rev[j][0] in '.,:/-+%٫٬' and j + 1 < len(rev) and rdirs[j + 1] in ('L', 'N'))):
                j += 1
            for cl in rev[i:j][::-1]:
                out.extend(cl)
            i = j
        else:
            cl = rev[i]
            out.extend(cl[1:])
            out.append(MIRROR.get(cl[0], cl[0]))  # brackets are drawn mirrored
            i += 1
    return ''.join(out)


def visual(word: str) -> str:
    """A word in the order its characters are drawn, left to right, chosen
    so PDF viewers (PDFium, the app's engine and Chrome's) turn it back
    into exactly the source text: right-to-left letters reversed with
    their diacritics, brackets mirrored, digits and Latin kept as they
    read. A diacritic on the word's last letter, right before closing
    punctuation ("قَالَ:", "عَيْنٍ."), is drawn ahead of the punctuation,
    or viewers would attach it to the punctuation instead."""
    k = len(word)
    while k > 0 and not _letterish(word[k - 1]) and not _is_mark(word[k - 1]):
        k -= 1
    j = k
    while j > 0 and _is_mark(word[j - 1]):
        j -= 1
    core, marks, punct = word[:j], word[j:k], word[k:]
    if core and marks and punct and not any(c in MIRROR for c in punct):
        return marks + _visual_core(punct) + _visual_core(core)
    return _visual_core(word)


def _same_line(a, b) -> bool:
    top, bottom = max(a[1], b[1]), min(a[3], b[3])
    return bottom - top >= 0.5 * min(a[3] - a[1], b[3] - b[1])


def _overlap(a, b) -> bool:
    ix = min(a[2], b[2]) - max(a[0], b[0])
    return _same_line(a, b) and ix > 0.6 * min(a[2] - a[0], b[2] - b[0])


def spread_shared(words: list[tuple[str, tuple]]) -> list[tuple[str, tuple]]:
    """Neighbouring words placed on (nearly) the same box share it out, in
    proportion to their letters, first word on the right: two words
    stacked on one spot would come out of a viewer jumbled."""
    out: list[tuple[str, tuple]] = []
    i = 0
    while i < len(words):
        j = i + 1
        while j < len(words) and _overlap(words[j - 1][1], words[j][1]):
            j += 1
        group = words[i:j]
        if len(group) == 1:
            out.append(group[0])
        else:
            x0 = min(b[0] for _, b in group)
            x1 = max(b[2] for _, b in group)
            y0 = min(b[1] for _, b in group)
            y1 = max(b[3] for _, b in group)
            weights = [max(1, len(w)) for w, _ in group]
            total = sum(weights)
            rtl = any(_dir(c) == 'R' for w, _ in group for c in w)
            pos = x1 if rtl else x0
            for (w, _), wt in zip(group, weights):
                width = (x1 - x0) * wt / total
                if rtl:
                    out.append((w, (pos - width, y0, pos, y1)))
                    pos -= width
                else:
                    out.append((w, (pos, y0, pos + width, y1)))
                    pos += width
        i = j
    return out


def page_stream(words: list[tuple[str, tuple]], to_pdf: pymupdf.Matrix) -> bytes:
    """Content stream of invisible text for one page: [words] are (word,
    box) in reading order, boxes in page coordinates (top-left origin)."""
    # Lines in reading order, each drawn left to right.
    lines: list[list[tuple[str, tuple]]] = []
    for w, b in words:
        if lines and _same_line(lines[-1][-1][1], b):
            lines[-1].append((w, b))
        else:
            lines.append([(w, b)])
    ops = ['BT', '3 Tr']
    size_now = None
    # The matrix applied by hand: a pymupdf Point times a Matrix for each of
    # a book's 115,000 words took 4 s of the text layer's 15.
    ma, mb, mc, md, me, mf = to_pdf.a, to_pdf.b, to_pdf.c, to_pdf.d, to_pdf.e, to_pdf.f
    for line in lines:
        for w, (x0, y0, x1, y1) in sorted(line, key=lambda wb: wb[1][0]):
            h, width = y1 - y0, x1 - x0
            if h <= 0.5 or width <= 0.5:
                continue
            # Each word ends with its space (drawn at its left, in visual
            # order), so copied text keeps its spaces.
            text = ' ' + visual(''.join(c if ord(c) <= 0xFFFF else '�' for c in w))
            size = round(h, 1)
            tz = 100 * width / (len(text) * ADVANCE / 1000 * size)
            # Baseline: the box's bottom, raised by the glyph's descent.
            px = x0 * ma + y1 * mc + me
            y = (x0 * mb + y1 * md + mf) - DESCENT / 1000 * size
            if size != size_now:
                ops.append(f'/{FONT_NAME} {size:g} Tf')
                size_now = size
            ops.append(f'{tz:.1f} Tz 1 0 0 1 {px:.2f} {y:.2f} Tm <{text.encode("utf-16-be").hex()}> Tj')
    ops.append('ET')
    return ('\n'.join(ops) + '\n').encode('ascii')


def _resources_xref(doc: pymupdf.Document, page: pymupdf.Page) -> tuple[str, int | None]:
    """Where the page's resources live: ('xref', n) for an object, ('inline',
    None) for a dictionary in the page itself."""
    kind, val = doc.xref_get_key(page.xref, 'Resources')
    if kind == 'xref':
        return 'xref', int(val.split()[0])
    if kind == 'dict':
        return 'inline', None
    # Inherited from the page tree: give the page its own reference to the
    # same resources, so adding to them does not hide anything.
    node = page.xref
    while True:
        pk, pv = doc.xref_get_key(node, 'Parent')
        if pk != 'xref':
            break
        node = int(pv.split()[0])
        rk, rv = doc.xref_get_key(node, 'Resources')
        if rk == 'xref':
            doc.xref_set_key(page.xref, 'Resources', rv)
            return 'xref', int(rv.split()[0])
        if rk == 'dict':
            doc.xref_set_key(page.xref, 'Resources', rv)
            return 'inline', None
    doc.xref_set_key(page.xref, 'Resources', '<<>>')
    return 'inline', None


def _add_font_resource(doc: pymupdf.Document, page: pymupdf.Page, font_xref: int):
    where, rx = _resources_xref(doc, page)
    holder, prefix = (rx, '') if where == 'xref' else (page.xref, 'Resources/')
    fk, fv = doc.xref_get_key(holder, prefix + 'Font')
    if fk == 'xref':
        doc.xref_set_key(int(fv.split()[0]), FONT_NAME, f'{font_xref} 0 R')
    else:
        doc.xref_set_key(holder, f'{prefix}Font/{FONT_NAME}', f'{font_xref} 0 R')


def _append_contents(doc: pymupdf.Document, page: pymupdf.Page, data: bytes):
    if not page.is_wrapped:
        page.wrap_contents()  # q ... Q around the original, so our text starts clean
    x = _new_stream(doc, '<<>>', data)
    ck, cv = doc.xref_get_key(page.xref, 'Contents')
    if ck == 'array':
        items = cv.strip()[1:-1].strip()
        doc.xref_set_key(page.xref, 'Contents', f'[{items} {x} 0 R]')
    elif ck == 'xref':
        doc.xref_set_key(page.xref, 'Contents', f'[{cv} {x} 0 R]')
    else:
        doc.xref_set_key(page.xref, 'Contents', f'{x} 0 R')


def page_has_text(page: pymupdf.Page) -> bool:
    return bool(page.get_text('rawdict', flags=0)['blocks']) and bool(page.get_text().strip())


def add_text_layer(doc: pymupdf.Document, pages: dict[int, list[tuple[str, tuple]]]) -> list[int]:
    """Writes invisible text on the given pages (0-based index -> (word,
    box) list in reading order). Returns the pages written."""
    font = None
    done = []
    for pi, words in sorted(pages.items()):
        words = spread_shared([(w, b) for w, b in words if b is not None and w])
        if not words:
            continue
        page = doc[pi]
        if page.rotation:
            continue  # boxes of rotated pages are not handled here
        if font is None:
            font = add_font(doc)
        _add_font_resource(doc, page, font)
        _append_contents(doc, page, page_stream(words, ~page.transformation_matrix))
        done.append(pi)
    return done
