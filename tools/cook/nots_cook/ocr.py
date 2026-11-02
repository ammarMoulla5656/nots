"""OCR for pages drawn as pictures (scans, covers, calligraphy).

MuPDF has Tesseract built in; it only needs the Arabic language data
(ara.traineddata), which is fetched once into tools/cook/tessdata. The OCR
text is used for where the words are; the words themselves come from the
source text when there is one (OCR misreads letters, the source does not).
"""

from __future__ import annotations

import os
import urllib.request
from pathlib import Path

import pymupdf

from .align import Decoder, DecodedPage, align, keep, source_skeleton, word_boxes
from .glyphs import Glyph
from .pipeline import log

HERE = Path(__file__).resolve().parent.parent
DATA_DIR = HERE / 'tessdata'
URL = 'https://github.com/tesseract-ocr/tessdata_best/raw/main/{lang}.traineddata'


def tessdata(lang: str = 'ara') -> str | None:
    """Folder holding {lang}.traineddata, fetched on first use."""
    env = os.environ.get('TESSDATA_PREFIX')
    if env and (Path(env) / f'{lang}.traineddata').exists():
        return env
    try:
        found = pymupdf.get_tessdata()
        if found and (Path(found) / f'{lang}.traineddata').exists():
            return found
    except Exception:
        pass
    target = DATA_DIR / f'{lang}.traineddata'
    if target.exists():
        return str(DATA_DIR)
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        log(f'  fetching the OCR language data ({lang}) once ...')
        tmp = target.with_suffix('.part')
        urllib.request.urlretrieve(URL.format(lang=lang), tmp)
        tmp.replace(target)
        return str(DATA_DIR)
    except Exception as e:
        log(f'  OCR not available ({e}); pages drawn as pictures keep their text without positions')
        return None


def ocr_words(page: pymupdf.Page, data: str, lang: str = 'ara', dpi: int = 300) -> list[tuple[str, tuple]]:
    """Words read on the page with their boxes, in reading order (lines top
    to bottom, right to left within a line)."""
    tp = page.get_textpage_ocr(language=lang, dpi=dpi, full=True, tessdata=data)
    raw = page.get_text('words', textpage=tp)
    lines: dict[tuple[int, int], list] = {}
    for x0, y0, x1, y1, w, block, line, _ in raw:
        lines.setdefault((block, line), []).append((w, (x0, y0, x1, y1)))
    ordered = sorted(lines.values(), key=lambda ws: min(b[1] for _, b in ws))
    out = []
    for ws in ordered:
        out += sorted(ws, key=lambda wb: -wb[1][2])
    return out


def place_words(doc: pymupdf.Document, analysis, pages, source, force: bool = False) -> dict:
    data = tessdata()
    if not data:
        return {'available': False}
    info = {'available': True, 'pages': {}}
    for pr in pages:
        page = doc[pr.number - 1]
        try:
            words = ocr_words(page, data)
        except Exception as e:
            info['pages'][pr.number] = f'failed: {e}'
            continue
        if source is not None and pr.number - 1 < len(source.pages):
            # One pseudo-glyph per OCR word: its letters form the skeleton.
            dec = DecodedPage()
            chars = []
            for k, (w, b) in enumerate(words):
                g = Glyph(seq=k, font='ocr', gid=-1, tu=w, x=b[0], y=b[3], bbox=b, size=b[3] - b[1])
                g.text = w
                g.line = int(b[1] // 6)
                for c in w:
                    if keep(c):
                        chars.append(c)
                        dec.owner.append(g)
            dec.skel = ''.join(chars)
            src = source_skeleton(source.pages[pr.number - 1])
            al = align(dec, src)
            boxes = word_boxes(dec, src, al)
            ratio = al.ratio(len(dec.skel), len(src.skel))
            # Handwriting and ornaments read badly: keep only confident pages.
            if ratio >= 0.45:
                pr.boxes = boxes
                pr.kind = 'ocr'
            info['pages'][pr.number] = {'words_read': len(words), 'match': round(ratio, 3),
                                        'used': ratio >= 0.45}
            log(f'  OCR page {pr.number}: {len(words)} words read, match with the text {ratio:.0%}'
                + ('' if ratio >= 0.45 else ' (too low, not used)'))
        else:
            pr.ocr_words = [(w, b) for w, b in words]
            pr.kind = 'ocr'
            info['pages'][pr.number] = {'words_read': len(words)}
            log(f'  OCR page {pr.number}: {len(words)} words')
    return info
