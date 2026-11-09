"""The books of the Masdar app ("المصدر"), to know a book's id there.

A book with a Masdar id shows Masdar's logo in the reader, and its pages
open in Masdar at https://alhikmeh.org/source/<id>/<volume>/<page>/0-1/ (the
same PDF pages in both). The list is `data/masdar_books.csv`, the library's
index (its first column is the id, written ID_7045).
"""

from __future__ import annotations

import csv
import os
import re
from dataclasses import dataclass
from functools import lru_cache

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_LIST = os.path.join(HERE, "data", "masdar_books.csv")

_DIACRITICS = re.compile("[ً-ْٰـ]")  # and tatweel
_NOT_LETTERS = re.compile(r"[^\w\s]", re.UNICODE)
_LETTERS = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ة": "ه", "ى": "ي", "ؤ": "و", "ئ": "ي"})


# Titles of respect: every author has one, so they tell no one apart.
_HONORIFICS = {"السيد", "الشيخ", "الميرزا", "العلامه", "الامام", "دام", "ظله", "قدس", "سره"}


def _author_words(author: str) -> set[str]:
    return set(normalize(author).split()) - _HONORIFICS


def normalize(text: str) -> str:
    """Without diacritics, punctuation or brackets; one form of each letter."""
    text = _DIACRITICS.sub("", text or "").translate(_LETTERS)
    text = re.sub(r"\(.*?\)", " ", text)  # (قدس سره) and the like
    text = _NOT_LETTERS.sub(" ", text)
    return " ".join(text.split())


# The categories as the Masdar app shows them (and the library already uses):
# the list names them at length.
_CATEGORIES = {
    "الفقه الإسلامي والأحكام": "الفقه",
    "أصول الفقه والقواعد الأصولية": "أصول الفقه",
    "النحو والصرف وعلوم اللغة": "اللغة",
    "الحديث الشريف وعلومه": "الحديث الشريف",
    "علم الرجال والدراية والتراجم": "الرجال",
    "العقائد والكلام": "العقيدة",
    "البلاغة والمعاني والبيان": "البلاغة",
    "التفسير وعلوم القرآن": "تفسير القرآن",
    "الأخلاق والآداب والسلوك": "الأخلاق",
    "المنطق والفلسفة الإسلامية": "المنطق",
}


def category(subject: str) -> str:
    """The category of a book of Masdar, by the name the app shows."""
    return _CATEGORIES.get(subject.strip(), subject.strip())


@dataclass(frozen=True)
class MasdarBook:
    id: int
    title: str
    subject: str
    author: str
    parts: int
    pages: int


@lru_cache(maxsize=4)
def load(path: str = DEFAULT_LIST) -> tuple[MasdarBook, ...]:
    if not os.path.exists(path):
        return ()
    out = []
    with open(path, encoding="utf-8-sig", newline="") as f:
        for row in csv.reader(f):
            if len(row) < 6:
                continue
            m = re.fullmatch(r"\s*ID_0*(\d+)\s*", row[0])
            if not m:
                continue  # the heading
            out.append(MasdarBook(
                id=int(m.group(1)),
                title=row[1].strip(),
                subject=row[2].strip(),
                author=row[3].strip(),
                parts=int(row[4]) if row[4].strip().isdigit() else 1,
                pages=int(row[5]) if row[5].strip().isdigit() else 0,
            ))
    return tuple(out)


def by_id(book_id: int, path: str = DEFAULT_LIST) -> MasdarBook | None:
    return next((b for b in load(path) if b.id == book_id), None)


def find(title: str, author: str = "", path: str = DEFAULT_LIST) -> list[MasdarBook]:
    """Books of Masdar that may be [title] (by [author]), the likeliest first.
    The same title comes first; a title containing the other next; the
    author decides between books of the same title."""
    t = normalize(title)
    if len(t) < 2:
        return []
    a = _author_words(author)
    scored = []
    for b in load(path):
        bt = normalize(b.title)
        if bt == t:
            score = 3
        elif len(t) >= 4 and (t in bt or bt in t):
            score = 2 if bt.startswith(t) or t.startswith(bt) else 1
        else:
            continue
        overlap = len(a & _author_words(b.author)) if a else 0
        scored.append((score, overlap, b))
    scored.sort(key=lambda x: (-x[0], -x[1], x[2].title))
    return [b for *_, b in scored]


def best(
    title: str,
    author: str = "",
    parts: int | None = None,
    path: str = DEFAULT_LIST,
) -> MasdarBook | None:
    """The book of Masdar to fill in without asking, or None when unsure.

    It has the very same title. Several books share titles (منهاج الصالحين
    has eight authors), so the author tells them apart, and between books of
    one author (two editions of المكاسب) the number of volumes [parts]."""
    found = [b for b in find(title, author, path) if normalize(b.title) == normalize(title)]
    a = _author_words(author)
    if len(found) > 1 and a:
        scores = {b.id: len(a & _author_words(b.author)) for b in found}
        top = max(scores.values())
        if top > 0:
            found = [b for b in found if scores[b.id] == top]
    if len(found) > 1 and parts:
        found = [b for b in found if b.parts == parts] or found
    return found[0] if len(found) == 1 else None
