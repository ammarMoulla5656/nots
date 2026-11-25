"""Reading pages with OCR: the language data, and one reading per page.

Nothing is downloaded: Tesseract's Arabic data is looked for next to this
tool, then where the machine keeps it. See engines.py for the engines.
"""

from __future__ import annotations

import os
from pathlib import Path

import pymupdf

from . import engines
from .engines import OcrWord

HERE = Path(__file__).resolve().parent.parent
DATA_DIR = HERE / 'tessdata'

# Worker processes for OCR; None: one per CPU core of the machine.
WORKERS: int | None = None


def tessdata(lang: str = 'ara') -> str | None:
    """Folder holding {lang}.traineddata, if this machine has one. The fast
    model (tessdata_fast, in tessdata/fast) first: on 24 pages of al-Ghadir
    it read 3.1 s a page against 22.7 s for the best model, with the same
    letters right (0.834 against 0.831). NOTS_TESS_MODEL=best for the other."""
    places = [os.environ.get('TESSDATA_PREFIX')]
    if os.environ.get('NOTS_TESS_MODEL', 'fast') == 'fast':
        places.append(str(DATA_DIR / 'fast'))
    places.append(str(DATA_DIR))
    exe = engines.find_tesseract()
    if exe:
        places.append(str(Path(exe).parent / 'tessdata'))
    try:
        places.append(pymupdf.get_tessdata())
    except Exception:
        pass
    for p in places:
        if p and (Path(p) / f'{lang}.traineddata').exists():
            return p
    return None


def one_reading(got: dict[str, list[OcrWord]], lexicon=frozenset(), speller=None,
                columns: bool = True) -> list[OcrWord]:
    """The best single reading of a page out of what each engine read."""
    words = engines.merge(got.get('tesseract') or got.get('mupdf') or [],
                          got.get('windows') or [], lexicon, columns)
    return speller.mend(words) if speller else words
