"""Glyph -> text maps of the fonts embedded in a PDF.

Word (and other producers) often write a broken /ToUnicode table for Arabic
fonts, so copying and searching give garbage although the page looks right.
The embedded font program itself still knows what every glyph is: its cmap
maps characters to the base glyphs, and its GSUB table derives the
contextual forms (initial, medial, final) and the ligatures from them. This
module rebuilds glyph -> text from those tables, reads the existing
/ToUnicode, and writes a corrected one.
"""

from __future__ import annotations

import io
import re
import unicodedata
from dataclasses import dataclass, field

import pymupdf
from fontTools.pens.boundsPen import BoundsPen
from fontTools.ttLib import TTFont

SUBSET_TAG = re.compile(r'^[A-Z]{6}\+')

# Brackets drawn mirrored in right-to-left text.
MIRROR = {'(': ')', ')': '(', '[': ']', ']': '[', '{': '}', '}': '{',
          '«': '»', '»': '«', '<': '>', '>': '<'}


def family_key(name: str) -> str:
    """Font name without the subset tag, e.g. 'almohsin,Bold'."""
    name = SUBSET_TAG.sub('', name.lstrip('/'))
    return name.replace('#20', ' ')


def base_family(name: str) -> str:
    """Font family without style suffix, e.g. 'almohsin'."""
    return family_key(name).split(',')[0]


def glyph_texts_from_font(buf: bytes) -> dict[int, str]:
    """gid -> text, read from the font's cmap and closed over its GSUB."""
    tt = TTFont(io.BytesIO(buf), lazy=True)
    order = tt.getGlyphOrder()
    gid = {n: i for i, n in enumerate(order)}
    out: dict[str, str] = {}
    try:
        cm = tt.getBestCmap() or {}
    except Exception:
        cm = {}
    presentation: list[tuple[str, str]] = []
    for u, g in sorted(cm.items()):
        if u < 0x20 or 0xE000 <= u <= 0xF8FF:
            continue  # control codes and private-use slots carry no text
        s = chr(u)
        if 0xFB50 <= u <= 0xFEFF:
            s = unicodedata.normalize('NFKC', s)
            if len(s) > 1:
                # A ligature: what its parts are is the font's own business.
                presentation.append((g, s))
                continue
        # A letter's code point (even as an initial, medial or final form)
        # names the letter exactly: the shaping rules may reach the same
        # glyph from two letters (yeh and alef maksura share forms).
        out.setdefault(g, s)
    lookups = []
    if 'GSUB' in tt:
        try:
            lookups = tt['GSUB'].table.LookupList.Lookup
        except Exception:
            lookups = []
    _close_gsub(out, lookups)
    # Presentation forms only for glyphs the shaping rules do not reach: the
    # rules say what a glyph stands for in this font (U+FDF2 "Allah" is
    # drawn after a separate alef here, so it stands for "لله"), while the
    # standard decomposition of the code point may say otherwise.
    added = False
    for g, s in presentation:
        if g not in out:
            out[g] = s
            added = True
    if added:
        _close_gsub(out, lookups)
    return {gid[n]: s for n, s in out.items() if n in gid}


def _close_gsub(out: dict[str, str], lookups) -> None:
    """Gives every glyph the shaping rules derive from known glyphs the text
    of its sources: forms inherit their letter, ligatures join theirs."""
    if lookups:
        changed = True
        while changed:
            changed = False
            for lk in lookups:
                for st in lk.SubTable:
                    t = lk.LookupType
                    if t == 7:
                        t = st.ExtensionLookupType
                        st = st.ExtSubTable
                    if t == 1:
                        for a, b in st.mapping.items():
                            if a in out and b not in out:
                                out[b] = out[a]
                                changed = True
                    elif t == 3:
                        for a, bs in st.alternates.items():
                            for b in bs:
                                if a in out and b not in out:
                                    out[b] = out[a]
                                    changed = True
                    elif t == 4:
                        for first, ligs in st.ligatures.items():
                            for lig in ligs:
                                comps = [first, *lig.Component]
                                if lig.LigGlyph not in out and all(c in out for c in comps):
                                    out[lig.LigGlyph] = ''.join(out[c] for c in comps)
                                    changed = True


def parse_tounicode(data: bytes) -> dict[int, str]:
    """Reads a /ToUnicode CMap (bfchar and bfrange) into code -> text,
    following the spec literally (so Word's broken ranges come out broken,
    exactly as viewers see them)."""
    m: dict[int, str] = {}
    t = data.decode('latin1')

    def hexstr(h: str) -> str:
        h = re.sub(r'\s', '', h)
        if len(h) % 4:
            h = h.rjust((len(h) + 3) // 4 * 4, '0')
        return bytes.fromhex(h).decode('utf-16-be', errors='replace')

    for blk in re.findall(r'beginbfchar(.*?)endbfchar', t, re.S):
        for a, b in re.findall(r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f\s]*)>', blk):
            m[int(a, 16)] = hexstr(b)
    for blk in re.findall(r'beginbfrange(.*?)endbfrange', t, re.S):
        for a, b, rest in re.findall(
                r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*(\[[^\]]*\]|<[0-9A-Fa-f\s]+>)', blk):
            lo, hi = int(a, 16), int(b, 16)
            if rest.startswith('['):
                for i, v in enumerate(re.findall(r'<([0-9A-Fa-f\s]*)>', rest)):
                    m[lo + i] = hexstr(v)
            else:
                base = hexstr(rest[1:-1])
                for i in range(hi - lo + 1):
                    m[lo + i] = base[:-1] + chr(ord(base[-1]) + i) if base else ''
    return m


def is_rtl_text(s: str) -> bool:
    return any(unicodedata.bidirectional(c) in ('R', 'AL') for c in s)


def tounicode_cmap(mapping: dict[int, str]) -> bytes:
    """A /ToUnicode CMap for 2-byte codes. Glyphs of right-to-left text are
    stored in visual order in the page, and viewers reverse each line,
    including the letters of one glyph: so a ligature's letters are written
    reversed, and come out right after the viewer's reversal."""
    lines = ['/CIDInit /ProcSet findresource begin', '12 dict begin', 'begincmap',
             '/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def',
             '/CMapName /Adobe-Identity-UCS def', '/CMapType 2 def',
             '1 begincodespacerange', '<0000> <FFFF>', 'endcodespacerange']
    items = sorted((c, s) for c, s in mapping.items() if s)
    for k in range(0, len(items), 100):
        chunk = items[k:k + 100]
        lines.append(f'{len(chunk)} beginbfchar')
        for code, s in chunk:
            if len(s) > 1 and is_rtl_text(s):
                s = s[::-1]
            lines.append('<%04X> <%s>' % (code, s.encode('utf-16-be').hex().upper()))
        lines.append('endbfchar')
    lines += ['endcmap', 'CMapName currentdict /CMap defineresource pop', 'end', 'end']
    return '\n'.join(lines).encode('ascii')


@dataclass
class PdfFont:
    xref: int
    name: str            # without subset tag
    subtype: str         # Type0, TrueType, ...
    identity: bool       # Type0 with Identity-H and CIDToGIDMap /Identity
    tounicode_xref: int  # 0 when absent
    tounicode: dict[int, str] = field(default_factory=dict)
    from_font: dict[int, str] = field(default_factory=dict)
    mark_ink: dict[int, tuple[float, float]] = field(default_factory=dict)


def _key(doc: pymupdf.Document, xref: int, key: str) -> tuple[str, str]:
    try:
        return doc.xref_get_key(xref, key)
    except Exception:
        return ('null', 'null')


def read_fonts(doc: pymupdf.Document) -> dict[int, PdfFont]:
    """Every font object used by a page, with both glyph -> text sources."""
    fonts: dict[int, PdfFont] = {}
    for page in doc:
        for f in page.get_fonts(full=True):
            xref = f[0]
            if xref in fonts or xref <= 0:
                continue
            subtype = _key(doc, xref, 'Subtype')[1].lstrip('/')
            identity = False
            if subtype == 'Type0':
                enc = _key(doc, xref, 'Encoding')[1]
                desc = _key(doc, xref, 'DescendantFonts')
                cid_to_gid = '/Identity'
                if desc[0] == 'array':
                    m = re.search(r'(\d+)\s+0\s+R', desc[1])
                    if m:
                        cid_to_gid = _key(doc, int(m.group(1)), 'CIDToGIDMap')[1]
                elif desc[0] == 'xref':
                    arr = doc.xref_object(int(desc[1].split()[0]))
                    m = re.search(r'(\d+)\s+0\s+R', arr)
                    if m:
                        cid_to_gid = _key(doc, int(m.group(1)), 'CIDToGIDMap')[1]
                identity = enc == '/Identity-H' and cid_to_gid in ('/Identity', 'null')
            tu = _key(doc, xref, 'ToUnicode')
            tu_xref = int(tu[1].split()[0]) if tu[0] == 'xref' else 0
            pf = PdfFont(xref=xref, name=family_key(f[3]), subtype=subtype,
                         identity=identity, tounicode_xref=tu_xref)
            if tu_xref:
                try:
                    pf.tounicode = parse_tounicode(doc.xref_stream(tu_xref) or b'')
                except Exception:
                    pf.tounicode = {}
            try:
                _, ext, _, buf = doc.extract_font(xref)
                if buf and ext in ('ttf', 'otf', 'cff', 'n/a'):
                    pf.from_font = glyph_texts_from_font(buf)
                    pf.mark_ink = mark_extents(buf, pf.from_font)
            except Exception:
                pf.from_font = {}
            fonts[xref] = pf
    return fonts


def family_maps(fonts: dict[int, PdfFont]) -> dict[str, dict[int, str]]:
    """gid -> text from the font programs, merged per font name: Word embeds
    the same font (same glyph ids) several times, some copies stripped of
    their tables. A bold face is a font of its own, with its own glyph ids."""
    fams: dict[str, dict[int, str]] = {}
    for pf in sorted(fonts.values(), key=lambda f: -len(f.from_font)):
        fam = fams.setdefault(pf.name, {})
        for g, s in pf.from_font.items():
            fam.setdefault(g, s)
    return fams


def family_mark_ink(fonts: dict[int, PdfFont]) -> dict[str, dict[int, tuple[float, float]]]:
    """Ink extents of the diacritic glyphs, merged per font name."""
    out: dict[str, dict[int, tuple[float, float]]] = {}
    for pf in fonts.values():
        m = out.setdefault(pf.name, {})
        for g, e in pf.mark_ink.items():
            m.setdefault(g, e)
    return out


def mark_extents(buf: bytes, texts: dict[int, str]) -> dict[int, tuple[float, float]]:
    """Left and right edge of the ink of each diacritic glyph, as fractions
    of the em from the glyph's origin: tells which letter it is drawn on."""
    try:
        tt = TTFont(io.BytesIO(buf), lazy=True)
        gs = tt.getGlyphSet()
        order = tt.getGlyphOrder()
        upem = tt['head'].unitsPerEm
    except Exception:
        return {}
    out = {}
    for gid, s in texts.items():
        if not s or not all(unicodedata.category(c) in ('Mn', 'Me') for c in s) or gid >= len(order):
            continue
        try:
            pen = BoundsPen(gs)
            gs[order[gid]].draw(pen)
        except Exception:
            continue
        if pen.bounds:
            out[gid] = (pen.bounds[0] / upem, pen.bounds[2] / upem)
    return out


def family_tounicode(fonts: dict[int, PdfFont]) -> dict[str, dict[int, str]]:
    """code -> text of the existing /ToUnicode, merged per font name, for
    Identity fonts (code == gid)."""
    fams: dict[str, dict[int, str]] = {}
    for pf in fonts.values():
        if pf.identity and pf.tounicode:
            fam = fams.setdefault(pf.name, {})
            for g, s in pf.tounicode.items():
                fam.setdefault(g, s)
    return fams
