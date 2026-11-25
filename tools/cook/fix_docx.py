"""Corrects the Hikmah library's Word files (كتب_المكتبة_docx) before they
are cooked with their PDF, so the text and the index match Hikmah and the
print exactly:

- "[صفحة N]" at the top of each page and "بياض مطابق للأصل" on blank pages
  are not in the print: they go, the page breaks stay (a blank page stays a
  page, empty, and gets no text).
- The index is Hikmah's own, from library.db (table Contents). The exporter
  wrote each entry twice: once at the top of its page, and once where the
  page's text has it. The copy at the top goes and the line in the text
  becomes the heading, so the bookmark sits where the print has it. Other
  lines in heading style (headings the text repeats, the book's name and
  author on its first page) become plain text.
- An entry counts only where its title is a line of the text, on its page
  or after it, in the index's order: library.db's index is not always of
  the text's edition (al-Kafi 1: same titles, other pages; Bihar: other
  volumes). When fewer than half its entries are found, the text's own
  heading lines are the index, each once. A text with no heading lines of
  its own keeps library.db's index: on the line found, else on top of the
  entry's page (many entries there sum up a paragraph, not a printed line).
- Index pages (a table of contents: most of its lines end in a page number)
  are emptied: the bookmarks hold the index, and the cook leaves an empty
  page alone.

    python fix_docx.py BOOK.docx [-o OUT.docx]
    python fix_docx.py FOLDER --out-dir FIXED   (every .docx in it)

The file name gives the book and volume, as the exporter wrote it:
[ID_034]_[...]_[الميزان_في_تفسير_القرآن]_ج06.docx. Without library.db or a
match there, the markers still go and headings repeated on the same or the
next page become text.
"""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
import time
import zipfile
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

LIBRARY = Path(__file__).resolve().parents[2] / 'library.db'
PARA = re.compile(r'<w:p\b(?:[^>]*/>|.*?</w:p>)', re.S)
TEXT = re.compile(r'<w:t(?:\s[^>]*)?>([^<]*)</w:t>')
STYLE = re.compile(r'<w:pStyle w:val="Heading(\d)"\s*/>')
PAGE_BREAK = 'w:type="page"'
MARKER = re.compile(r'^\s*\[\s*صفحة\s*[\d٠-٩]+\s*\]\s*$')
BLANK = re.compile(r'^\s*بياض\s+مطابق\s+للأصل\s*$')
# An older export's page badge: "❖  [ID: 1213] مرآة الكمال - الجزء 02 - صفحة 2 ❖".
BADGE = re.compile(r'^\s*❖.*صفحة\s*[\d٠-٩]+\s*❖?\s*$')
NAME = re.compile(r'^\[ID_(\d+)\].*?_ج(\d+)$')


def letters(s: str) -> str:
    """Arabic letters and digits only: no diacritics, brackets or marks."""
    s = re.sub(r'[ً-ٰٟـ]', '', s)
    s = ''.join(ch for ch in s if ch.isalnum())
    return s.translate(str.maketrans('أإآٱىة', 'اااايه'))


def text_of(p: str) -> str:
    import html
    return html.unescape(''.join(TEXT.findall(p)))


def level_of(p: str) -> int | None:
    m = STYLE.search(p)
    return int(m.group(1)) if m else None


def with_level(p: str, level: int | None) -> str:
    p = STYLE.sub('', p)
    if level is None:
        return p.replace('<w:pPr></w:pPr>', '')
    tag = f'<w:pStyle w:val="Heading{level}"/>'
    if '<w:pPr>' in p:
        return p.replace('<w:pPr>', '<w:pPr>' + tag, 1)
    if '<w:pPr/>' in p:
        return p.replace('<w:pPr/>', f'<w:pPr>{tag}</w:pPr>', 1)
    return re.sub(r'^(<w:p\b[^>]*>)', r'\1<w:pPr>' + tag + '</w:pPr>', p, count=1)


FOOTNOTE = re.compile(r'^\s*[(\[]\s*[\d٠-٩]+\s*[)\]]|^\s*_{4,}\s*$')
INDEX_TITLE = re.compile(r'^\s*(?:ال)?(?:فهرس|فهارس|فهرست|محتويات)')


def index_page(texts: list[str], after_index: bool) -> bool:
    """A table of contents. Lines ending in numbers are not enough: a text
    page with many footnotes ("(١) البقرة: ٢٦.") has them too. So a page is
    an index when it opens with a title saying so and half its lines end in
    a page number, or when it follows an index page with no footnotes and
    nearly every line ending in a page number."""
    lines = [t.strip() for t in texts if t.strip()]
    if any(FOOTNOTE.match(t) for t in lines):
        return False
    lines = [t for t in lines if not MARKER.match(t) and not BADGE.match(t)]
    if len(lines) < 4:
        return False
    numbered = sum(1 for t in lines if re.search(r'[\d٠-٩]+\s*$', re.sub(r'[.\-–_…\s]+$', '', t)))
    if any(INDEX_TITLE.match(t) for t in lines[:2]):
        return numbered >= 0.5 * (len(lines) - 1)
    return after_index and numbered >= 0.8 * len(lines)


def contents_of(stem: str, library: Path, part: int | None = None) -> dict[int, list[tuple[int, str]]] | None:
    """The index of a volume: by its part id when it is known (exact), else
    from the exporter's file name (book id and volume number)."""
    if not library.exists():
        return None
    c = sqlite3.connect(f'file:{library}?mode=ro', uri=True)
    rows = []
    if part:
        rows = c.execute('select pageID, level, title from Contents where partID = ? order by id',
                         (int(part),)).fetchall()
    m = NAME.match(stem)
    if not rows and m:
        rows = c.execute('select pageID, level, title from Contents where bookID = ? and joze = ? order by id',
                         (int(m.group(1)), int(m.group(2)))).fetchall()
        if not rows:  # a book of one volume: joze 0 or 1
            rows = c.execute('select pageID, level, title from Contents where bookID = ? order by id',
                             (int(m.group(1)),)).fetchall()
    c.close()
    out: dict[int, list[tuple[int, str]]] = {}
    for page, level, title in rows:
        out.setdefault(int(page), []).append((int(level or 1), ' '.join((title or '').split())))
    return out or None


def fix(xml: str, contents: dict[int, list[tuple[int, str]]] | None) -> tuple[str, dict]:
    body_start = xml.index('<w:body>') + len('<w:body>')
    body_end = xml.rindex('<w:sectPr') if '<w:sectPr' in xml[body_start:] else xml.rindex('</w:body>')
    paras = PARA.findall(xml[body_start:body_end])
    # Pages: runs of paragraphs between page-break paragraphs.
    pages: list[list[str]] = [[]]
    for p in paras:
        pages[-1].append(p)
        if PAGE_BREAK in p:
            pages.append([])
    stats = {'pages': len(pages), 'markers': 0, 'blank': 0, 'headings': 0, 'placed': 0,
             'kept_on_top': 0, 'unstyled': 0, 'index_pages': [], 'index': 'none'}
    # 1. Each page without the export's additions.
    clean: list[tuple[int, list[str]]] = []   # (printed number, paragraphs)
    for n, page in enumerate(pages, 1):
        kept = []
        number = None
        for p in page:
            t = text_of(p)
            if MARKER.match(t) or BADGE.match(t):
                digits = t.translate(str.maketrans('٠١٢٣٤٥٦٧٨٩', '0123456789'))
                number = int(re.findall(r'صفحة\s*(\d+)', digits)[-1])
                stats['markers'] += 1
                continue
            if BLANK.match(t):
                stats['blank'] += 1
                continue
            kept.append(p)
        after_index = bool(stats['index_pages']) and stats['index_pages'][-1] == n - 1
        if index_page([text_of(p) for p in kept], after_index):
            stats['index_pages'].append(n)
            kept = [p for p in kept if PAGE_BREAK in p]
        entries = contents.get(number or n, []) if contents else []
        # The export's copies of the page's index entries come first.
        top = 0
        while top < len(kept) and top < len(entries) and level_of(kept[top]) is not None \
                and letters(text_of(kept[top])) == letters(entries[top][1]):
            top += 1
        clean.append((number or n, kept[top:]))

    # 2. Where each entry of the index is in the text. The index of library.db
    # is not always of the same edition as the text (al-Kafi, Bihar: its pages
    # and volumes differ), so an entry counts only where its title is a line
    # of the text: on its page, or after it, in the index's order.
    flat = [(pi, li) for pi, (_, ps) in enumerate(clean) for li in range(len(ps))]
    keys = [letters(text_of(clean[pi][1][li])) for pi, li in flat]
    styled = [level_of(clean[pi][1][li]) is not None for pi, li in flat]
    first_of_page: dict[int, int] = {}
    for k, (pi, _) in enumerate(flat):
        first_of_page.setdefault(clean[pi][0], k)
    page_of = {pi: number for pi, (number, _) in enumerate(clean)}

    def first_line_from(number: int) -> int:
        """The first line on page [number] or the page after it."""
        later = [k for n, k in first_of_page.items() if n >= number]
        return min(later) if later else len(flat)

    level_at: dict[int, int] = {}
    entries = [(number, level, title) for number in sorted(contents or {}) for level, title in contents[number]]
    missing: list[tuple[int, int, str]] = []
    cursor = 0
    for number, level, title in entries:
        want = letters(title)
        # A few pages back too: some indexes number the pages a page or two
        # off the text (al-Muhkam: the index's page 9 is the text's page 7).
        start = max(cursor, first_line_from(number - 5))
        hit = None
        for k in range(start, len(flat)):
            if page_of[flat[k][0]] > number + 60:
                break
            got = keys[k]
            if k not in level_at and want and (got == want or (len(want) >= 3 and styled[k] and got.startswith(want))):
                hit = k
                break
        if hit is None:
            missing.append((number, level, title))
        else:
            level_at[hit] = level
            cursor = hit + 1
    own_headings = any(styled)
    if entries and len(level_at) >= 0.5 * len(entries):
        stats['index'] = 'library.db'
    elif entries and not own_headings:
        # The text marks no headings of its own, and many index entries are
        # summaries of a paragraph, not a printed line: the index stays, on
        # the line where the text has it, else on top of its page.
        stats['index'] = f'library.db, {len(level_at)} of {len(entries)} found as lines of the text'
    else:
        # The index is not this text's: its own heading lines are, each once
        # (the text repeats a heading over the next pages of its section).
        stats['index'] = 'the text\'s own headings (library.db did not fit)' if entries else \
            'the text\'s own headings'
        level_at, missing = {}, []
        seen_on: dict[str, int] = {}
        for k, (pi, li) in enumerate(flat):
            if styled[k] and keys[k]:
                if seen_on.get(keys[k], -9) < pi - 1:
                    level_at[k] = level_of(clean[pi][1][li])
                seen_on[keys[k]] = pi

    # 3. The pages, with the index where it was found.
    on_top: dict[int, list[tuple[int, str]]] = {}
    for number, level, title in missing:  # not found in the text: on top of its page
        on_top.setdefault(number, []).append((level, title))
    out_pages = []
    k = 0
    for number, ps in clean:
        new = [f'<w:p><w:pPr><w:pStyle w:val="Heading{level}"/><w:bidi/></w:pPr>'
               f'<w:r><w:t xml:space="preserve">{html_escape(title)}</w:t></w:r></w:p>'
               for level, title in on_top.pop(number, [])]
        stats['kept_on_top'] += len(new)
        for p in ps:
            want = level_at.get(k)
            if want is not None:
                stats['placed'] += 1
            elif level_of(p) is not None:
                stats['unstyled'] += 1
            new.append(with_level(p, want) if want != level_of(p) else p)
            k += 1
        out_pages.append(''.join(new))
    stats['dropped'] = sum(len(v) for v in on_top.values())  # pages the text does not have
    stats['headings'] = stats['placed'] + stats['kept_on_top']
    return xml[:body_start] + ''.join(out_pages) + xml[body_end:], stats


def html_escape(s: str) -> str:
    import html
    return html.escape(s, quote=False)


def fix_file(src: str, out: str, library: str, name: str | None = None, part: int | None = None) -> str:
    """[name]: the exporter's file name (without .docx), when the file was
    renamed: it tells the book and volume, e.g. "[ID_034]_..._ج06". [part]:
    the volume's part id in library.db, when known (it is exact)."""
    t = time.time()
    src_p, out_p = Path(src), Path(out)
    contents = contents_of(name or src_p.stem, Path(library), part)
    with zipfile.ZipFile(src_p) as z:
        items = [(i, z.read(i.filename)) for i in z.infolist()]
    doc = next(d for i, d in items if i.filename == 'word/document.xml').decode('utf-8')
    fixed, s = fix(doc, contents)
    out_p.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_p.with_suffix('.part')
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as z:
        for i, d in items:
            z.writestr(i, fixed.encode('utf-8') if i.filename == 'word/document.xml' else d)
    tmp.replace(out_p)
    return (f'{src_p.name}: {s["pages"]} pages, {s["headings"]} headings (index: {s["index"]}; '
            f'{s["placed"]} on their line in the text, {s["kept_on_top"]} kept on top), '
            f'{s["unstyled"]} heading lines made text, {s["markers"]} page markers and '
            f'{s["blank"]} blank-page notes removed'
            + (f', index pages emptied: {s["index_pages"]}' if s['index_pages'] else '')
            + f' ({time.time() - t:.2f}s)')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('path', type=Path, help='a .docx, or a folder of them')
    ap.add_argument('-o', '--out', type=Path, help='the corrected file (one file)')
    ap.add_argument('--out-dir', type=Path, help='folder for the corrected files (default: next to each, .fixed.docx)')
    ap.add_argument('--library', type=Path, default=LIBRARY)
    a = ap.parse_args()
    files = sorted(a.path.glob('*.docx')) if a.path.is_dir() else [a.path]
    files = [f for f in files if not f.name.endswith('.fixed.docx')]
    if not files:
        sys.exit('no .docx files')

    def target(f: Path) -> Path:
        if a.out and len(files) == 1:
            return a.out
        if a.out_dir:
            return a.out_dir / f.name
        return f.with_name(f.stem + '.fixed.docx')

    jobs = [(str(f), str(target(f)), str(a.library)) for f in files]
    if len(jobs) == 1:
        print(fix_file(*jobs[0]))
        return
    t = time.time()
    with ProcessPoolExecutor() as ex:
        for line in ex.map(fix_file, *zip(*jobs)):
            print(line, flush=True)
    print(f'{len(jobs)} files in {time.time() - t:.1f}s')


if __name__ == '__main__':
    main()
