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
        return '\n'.join(p for p in self.paragraphs if p)

    def words(self) -> list[str]:
        return self.text.split()


@dataclass
class SourceText:
    pages: list[SourcePage]
    headings: list[Heading]
    name: str = ''


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
                if any(pages[-1].paragraphs) or buf:
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


def read_source(path: Path, drop: list[str] = DEFAULT_DROP) -> SourceText:
    if path.suffix.lower() == '.docx':
        return read_docx(path, drop)
    return read_plain(path, drop)
