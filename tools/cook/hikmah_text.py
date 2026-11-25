"""Writes one volume of a book from the Hikmah database (alhikmeh_repaired.db)
as a text the cook reads: one printed page per form feed, headings on lines
starting with '#'. Hikmah keeps each printed page whole under its own number,
where an EPUB of the same book can merge pages (al-Mizan 6: 85 of 373 EPUB
pages empty, their text on the page before), so its pages and its index fall
where the print has them.

    python hikmah_text.py "الميزان في تفسير القرآن" 6 -o mizan6.txt
    python hikmah_text.py --part 2539 -o mizan6.txt
    python hikmah_text.py --list الميزان

The index is the <head1>/<head2> tags in the page text. A heading repeated
at the top of the pages its section runs on is kept on its first page only.
The book's name and author, tagged on its first page, are left out of the
index (they stay in the text).
"""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from pathlib import Path

DB = Path(__file__).resolve().parents[2] / 'alhikmeh_repaired.db'
HEAD = re.compile(r'<head(\d)>(.*?)</head\d>', re.S)
TAG = re.compile(r'<[^>]+>')


def one_line(s: str) -> str:
    return ' '.join(TAG.sub(' ', s).split())


def volumes(c: sqlite3.Connection, book_id: int, name: str) -> list[int]:
    """The book's part ids in volume order. The repair filed the volume
    records into MeaningLang (word = book id, meaning = volume number), and
    lost some of them; then the volumes are the parts whose first page is
    headed with the book's name, in the order of their ids."""
    rows = c.execute("select id, meaning from MeaningLang where word = ?", (str(book_id),)).fetchall()
    if rows:
        def number(v):
            v = (v or '').strip().translate(str.maketrans('٠١٢٣٤٥٦٧٨٩', '0123456789'))
            return int(v) if v.isdigit() else 0
        return [pid for pid, v in sorted(rows, key=lambda r: (number(r[1]), r[0]))]
    found = c.execute("select distinct part_id from BookPages where text like ? order by part_id",
                      (f'%<head1>{name}%',)).fetchall()
    return [r[0] for r in found]


def export(c: sqlite3.Connection, part: int, out: Path, drop_titles: set[str]) -> tuple[int, int]:
    pages = c.execute("select page_id, text from BookPages where part_id = ? order by page_id",
                      (part,)).fetchall()
    if not pages:
        sys.exit(f'part {part}: no pages in the database')
    by_number = dict(pages)
    first, last = pages[0][0], pages[-1][0]
    chunks, previous, headings = [], set(), 0
    for n in range(first, last + 1):
        text = by_number.get(n) or ''
        here = set()
        lines = []

        def heading(m):
            nonlocal headings
            level, title = int(m.group(1)), one_line(m.group(2))
            here.add(title)
            if not title or title in previous:
                return '\n'  # the section's heading again, over its next page
            bare = title.rstrip('‏')
            # The author's name is tagged without the "(قدس سره)" Books has.
            if any(d.startswith(bare) or bare.startswith(d) for d in drop_titles if len(bare) > 5):
                return f'\n{title}\n'
            headings += 1
            return f'\n{"#" * level} {title}\n'

        for line in HEAD.sub(heading, text).splitlines():
            if line.startswith('#'):
                lines.append(line)
            else:
                line = one_line(line)
                if line:
                    lines.append(line)
        previous = here
        chunks.append('\n'.join(lines))
    out.write_text('\f'.join(chunks), 'utf-8')
    return last - first + 1, headings


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('book', nargs='?', help="the book's name as Hikmah has it")
    ap.add_argument('volume', nargs='?', type=int, default=1)
    ap.add_argument('--part', type=int, help='the part id, in place of a name and volume')
    ap.add_argument('--list', metavar='WORD', help='books whose name holds WORD, with their volumes')
    ap.add_argument('--db', default=str(DB))
    ap.add_argument('-o', '--out')
    a = ap.parse_args()
    c = sqlite3.connect(f'file:{a.db}?mode=ro', uri=True)

    if a.list:
        for bid, name, author, parts in c.execute(
                "select id, book_name, authorName, parts_count from Books where book_name like ?",
                (f'%{a.list}%',)):
            print(f'{bid}\t{name}\t{author}\t{parts} volumes: parts {volumes(c, bid, name)}')
        return

    drop: set[str] = set()
    if a.part:
        part = a.part
    else:
        row = c.execute("select id, book_name, authorName from Books where book_name = ?", (a.book,)).fetchone()
        if not row:
            sys.exit(f'not in Hikmah: {a.book} (try --list)')
        parts = volumes(c, row[0], row[1])
        if not 1 <= a.volume <= len(parts):
            sys.exit(f'{a.book}: {len(parts)} volumes found, not {a.volume}')
        part = parts[a.volume - 1]
        drop = {row[1], row[2]}
    if not drop:
        row = c.execute("select text from BookPages where part_id = ? order by page_id limit 1", (part,)).fetchone()
        heads = [one_line(t) for _, t in HEAD.findall(row[0] if row else '')]
        name = c.execute("select book_name, authorName from Books where ? in (book_name, authorName)",
                         (heads[0].rstrip('‏') if heads else '',)).fetchone()
        drop = set(name) if name else set()
    out = Path(a.out or f'hikmah_{part}.txt')
    n, h = export(c, part, out, {d.rstrip('‏') for d in drop})
    print(f'part {part}: {n} pages, {h} headings -> {out}')


if __name__ == '__main__':
    main()
