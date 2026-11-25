"""The book's clean text, page by page, from a Word file (or plain text).

Pages split at explicit page breaks, exactly like the app's own Word
reader, so page N of the text is page N of the PDF. Editorial notes that
describe the page instead of being on it ("[صفحة بصورة مطابق للأصل]",
"بياض مطابق للأصل") are removed from the text and kept as page notes.
"""

from __future__ import annotations

import html
import re
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

# Notes of the transcriber, not text of the book.
DEFAULT_DROP = [
    r'\[[^\[\]]*مطابق\s+للأصل[^\[\]]*\]',
    r'^\s*بياض\s+مطابق\s+للأصل\s*$',
    # A page marker some synced copies insert for their own page-matching
    # ("[صفحة 21]", "[ص5]"): metadata about the copy, not book text.
    r'\[\s*ص(?:فحة)?\s*\d+\s*\]',
]

INVISIBLE = dict.fromkeys(map(ord, '‎‏‪‫‬‭‮﻿­'), None)


@dataclass
class Heading:
    title: str
    level: int
    page: int        # 1-based
    paragraph: int   # index in the page's paragraphs


@dataclass
class SourcePage:
    paragraphs: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def text(self) -> str:
        """Paragraphs joined by line breaks, words by single spaces: the only
        two separators readers of the word map split on."""
        return '\n'.join(' '.join(p.split()) for p in self.paragraphs if p.split())

    def words(self) -> list[str]:
        return self.text.split()


@dataclass
class SourceText:
    pages: list[SourcePage]
    headings: list[Heading]
    name: str = ''
    # Set when the source's own page 1 is not the PDF's page 1 (an EPUB
    # whose first numbered page is, say, 3): see pagematch.py.
    first_page_number: int = 1


def _heading_styles(styles_xml: str | None) -> dict[str, int]:
    levels: dict[str, int] = {}
    if not styles_xml:
        return levels
    for m in re.finditer(r'<w:style\b[^>]*w:styleId="([^"]+)"[^>]*>(.*?)</w:style>', styles_xml, re.S):
        name = re.search(r'<w:name w:val="([^"]+)"', m.group(2))
        lvl = re.match(r'^heading (\d)$', name.group(1), re.I) if name else None
        if lvl:
            levels[m.group(1)] = int(lvl.group(1))
    return levels


_PARA = re.compile(r'<w:p\b[^>]*?(?:/>|>(.*?)</w:p>)', re.S)
_TOKEN = re.compile(
    r'<w:t(?:\s[^>]*)?>([^<]*)</w:t>'
    r'|<w:tab/>'
    r'|<w:br\b([^>]*)/>'
    r'|<w:pageBreakBefore(?:\s+w:val="(?:true|1|on)")?\s*/>'
    r'|<w:pStyle w:val="([^"]+)"\s*/>'
    r'|<w:outlineLvl w:val="(\d)"\s*/>')


def _clean(s: str, drop: list[re.Pattern]) -> tuple[str, list[str]]:
    notes = []
    for rx in drop:
        notes += [m.group(0).strip() for m in rx.finditer(s)]
        s = rx.sub(' ', s)
    return re.sub(r'[ \t ]+', ' ', s).strip(), notes


def read_docx(path: Path, drop: list[str] = DEFAULT_DROP) -> SourceText:
    drop_rx = [re.compile(p, re.M) for p in drop]
    with zipfile.ZipFile(path) as z:
        xml = z.read('word/document.xml').decode('utf-8', 'replace')
        styles = z.read('word/styles.xml').decode('utf-8', 'replace') if 'word/styles.xml' in z.namelist() else None
    # Content written twice for old readers: keep only the modern copy.
    xml = re.sub(r'<mc:Fallback>.*?</mc:Fallback>', '', xml, flags=re.S)
    heading_styles = _heading_styles(styles)

    pages = [SourcePage()]
    headings: list[Heading] = []

    for pm in _PARA.finditer(xml):
        body = pm.group(1) or ''
        buf: list[str] = []
        level = None
        start_page = None

        def flush():
            text, notes = _clean(''.join(buf).translate(INVISIBLE), drop_rx)
            pages[-1].notes += notes
            pages[-1].paragraphs.append(text)
            buf.clear()

        for t in _TOKEN.finditer(body):
            s = t.group(0)
            if t.group(1) is not None:
                piece = html.unescape(t.group(1))
                if piece:
                    if start_page is None:
                        start_page = len(pages)
                    buf.append(piece)
            elif s == '<w:tab/>':
                buf.append(' ')
            elif s.startswith('<w:br'):
                if 'w:type="page"' in (t.group(2) or ''):
                    flush()
                    pages.append(SourcePage())
                else:
                    buf.append(' ')
            elif s.startswith('<w:pageBreakBefore'):
                # Skip only when nothing at all has been flushed to the
                # current page yet (this is the very first paragraph of the
                # document): a page of only blank paragraphs still counts,
                # so a run of empty paragraphs before a break is not lost.
                if pages[-1].paragraphs or buf:
                    if buf:
                        flush()
                    pages.append(SourcePage())
            elif t.group(3) is not None:
                if level is None:
                    level = heading_styles.get(t.group(3))
                    if level is None:
                        m = re.match(r'^Heading(\d)$', t.group(3))
                        level = int(m.group(1)) if m else None
            elif t.group(4) is not None:
                if level is None:
                    level = int(t.group(4)) + 1
        flush()
        if level is not None and level <= 6:
            # The heading is the last non-empty paragraph written for it.
            page_no = len(pages)
            para = len(pages[-1].paragraphs) - 1
            title = pages[-1].paragraphs[para] if para >= 0 else ''
            if title:
                headings.append(Heading(title, level, page_no, para))
    return SourceText(pages=pages, headings=headings, name=path.name)


def read_plain(path: Path, drop: list[str] = DEFAULT_DROP) -> SourceText:
    """UTF-8 text; pages separated by form feeds (\\f), paragraphs by lines.
    Lines starting with '#', '##', ... are headings."""
    drop_rx = [re.compile(p, re.M) for p in drop]
    pages = []
    headings = []
    for pi, chunk in enumerate(path.read_text('utf-8').translate(INVISIBLE).split('\f')):
        page = SourcePage()
        for line in chunk.splitlines():
            m = re.match(r'^(#{1,6})\s+(.*)$', line)
            text, notes = _clean(m.group(2) if m else line, drop_rx)
            page.notes += notes
            page.paragraphs.append(text)
            if m and text:
                headings.append(Heading(text, len(m.group(1)), pi + 1, len(page.paragraphs) - 1))
        pages.append(page)
    return SourceText(pages=pages, headings=headings, name=path.name)


_EPUB_BLOCK = re.compile(
    r'<(h[1-4]|p|div)\b([^>]*)>(.*?)</\1>', re.S)
_EPUB_CLASS = re.compile(r'class="([^"]*)"')
_EPUB_PAGEN = re.compile(r'<p\s+class="pagen"\s*>\s*(\d+)\s*</p>', re.S)


_SHAMELA_FOOTER = re.compile(r'الجزء:\s*(\d+)\s*¦\s*الصفحة:\s*(\d+)')
_SHAMELA_TITLE = re.compile(r'<span\b[^>]*class="title"[^>]*>(.*?)</span>', re.S)


def _read_shamela_epub(z: zipfile.ZipFile, drop: list[re.Pattern], name: str) -> SourceText | None:
    """The EPUB of shamela.ws: a file for each page, with no spine and with the
    printed volume and page in a footer. Pages missing from a volume stay as
    empty pages, for the numbering to follow the PDF."""
    found: dict[tuple[int, int], SourcePage] = {}
    titles: list[tuple[tuple[int, int], Heading]] = []
    for fname in z.namelist():
        if not fname.lower().endswith(('.xhtml', '.html')):
            continue
        html = z.read(fname).decode('utf-8', 'replace')
        footer = _SHAMELA_FOOTER.search(html)
        if not footer:
            continue
        key = (int(footer.group(1)), int(footer.group(2)))
        page = found.setdefault(key, SourcePage())
        body = html[html.find('<hr/>') + 5:footer.start()]
        for piece in re.split(r'<br\s*/?>|<hr\s*/?>', body):
            text, notes = _clean(_epub_text(piece), drop)
            page.notes += notes
            if text:
                page.paragraphs.append(text)
                title = _SHAMELA_TITLE.search(piece)
                if title:
                    titles.append((key, Heading(text, 2, 0, len(page.paragraphs) - 1)))
    if not found:
        return None
    pages: list[SourcePage] = []
    where: dict[tuple[int, int], int] = {}
    for volume in sorted({k[0] for k in found}):
        numbers = [k[1] for k in found if k[0] == volume]
        for n in range(min(numbers), max(numbers) + 1):
            pages.append(found.get((volume, n), SourcePage()))
            where[(volume, n)] = len(pages)
    headings = sorted((Heading(h.title, h.level, where[k], h.paragraph) for k, h in titles),
                      key=lambda h: (h.page, h.paragraph))  # the files come in no order
    text = SourceText(pages=pages, headings=headings, name=name)
    text.first_page_number = min(found)[1]
    return text


def _epub_text(html: str) -> str:
    html = re.sub(r'<(script|style)\b.*?</\1>', '', html, flags=re.S)
    text = re.sub(r'<[^>]+>', '', html)
    return re.sub(r'[ \t ]+', ' ', html_unescape(text)).strip()


def html_unescape(s: str) -> str:
    import html
    return html.unescape(s)


def read_epub(path: Path, drop: list[str] = DEFAULT_DROP) -> SourceText:
    """Reads an EPUB built from a print edition that marks each page's
    start with <p class="pagen">N</p> (a common convention: this is how
    shamela.ws/turath.io-style EPUBs and Sigil-made ones keep the print
    page numbers). [pages] is indexed from 0 for the book's own first
    numbered page (see first_page_number): page N of the print book is
    pages[N - first_page_number], not necessarily pages[N - 1] — text
    before the first page marker (a cover, a title page) has no number and
    is dropped, since nothing anchors it to a PDF page either."""
    drop_rx = [re.compile(p, re.M) for p in drop]
    with zipfile.ZipFile(path) as z:
        container = z.read('META-INF/container.xml').decode('utf-8', 'replace')
        opf_path = re.search(r'full-path="([^"]+)"', container).group(1)
        opf_dir = opf_path.rsplit('/', 1)[0] + '/' if '/' in opf_path else ''
        opf = z.read(opf_path).decode('utf-8', 'replace')
        manifest = dict(re.findall(r'<item\b[^>]*\bid="([^"]+)"[^>]*\bhref="([^"]+)"', opf))
        # id and href can appear in either order.
        manifest.update({i: h for h, i in re.findall(
            r'<item\b[^>]*\bhref="([^"]+)"[^>]*\bid="([^"]+)"', opf)})
        spine = re.findall(r'<itemref\b[^>]*\bidref="([^"]+)"', opf)
        files = [opf_dir + manifest[i] for i in spine
                 if i in manifest and manifest[i].lower().endswith(('.xhtml', '.html', '.htm'))]

        pages: dict[int, SourcePage] = {}
        headings: list[tuple[int, Heading]] = []
        cur_number: int | None = None
        cur_page: SourcePage | None = None
        for fname in files:
            html = z.read(fname).decode('utf-8', 'replace')
            html = re.sub(r'<mc:Fallback>.*?</mc:Fallback>', '', html, flags=re.S)
            pos = 0
            chunks: list[tuple[int | None, str]] = []  # (new page number or None, html)
            for m in _EPUB_PAGEN.finditer(html):
                chunks.append((None, html[pos:m.start()]))
                chunks.append((int(m.group(1)), ''))
                pos = m.end()
            chunks.append((None, html[pos:]))
            for number, html_piece in chunks:
                if number is not None:
                    cur_number = number
                    cur_page = pages.setdefault(cur_number, SourcePage())
                    continue
                if cur_page is None:
                    continue  # before the first page marker: not part of any PDF page
                for bm in _EPUB_BLOCK.finditer(html_piece):
                    tag, attrs, inner = bm.group(1), bm.group(2), bm.group(3)
                    text, notes = _clean(_epub_text(inner), drop_rx)
                    cur_page.notes += notes
                    if not text:
                        continue
                    cur_page.paragraphs.append(text)
                    cls = (_EPUB_CLASS.search(attrs) or [None, ''])[1] if attrs else ''
                    m = re.match(r'tit(\d)$', cls or '') or re.match(r'^h([1-4])$', tag)
                    if m:
                        headings.append((cur_number, Heading(
                            text, int(m.group(1)), cur_number, len(cur_page.paragraphs) - 1)))
        if not pages:
            shamela = _read_shamela_epub(z, drop_rx, path.name)
            if shamela:
                return shamela

    if not pages:
        raise ValueError(f'{path.name}: no page markers found')
    first, last = min(pages), max(pages)
    out_pages = [pages.get(n, SourcePage()) for n in range(first, last + 1)]
    out_headings = [Heading(h.title, h.level, n - first + 1, h.paragraph) for n, h in headings]
    text = SourceText(pages=out_pages, headings=out_headings, name=path.name)
    text.first_page_number = first
    return text


def read_source(path: Path, drop: list[str] = DEFAULT_DROP) -> SourceText:
    if path.suffix.lower() == '.docx':
        return read_docx(path, drop)
    if path.suffix.lower() == '.epub':
        return read_epub(path, drop)
    return read_plain(path, drop)
