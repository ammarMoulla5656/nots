"""Reads page images with Apple's Vision OCR (macOS only), the way winocr.ps1 does with Windows' OCR.

    python visionocr.py --probe                      prints the Arabic language Vision can read, exit 2 if none
    python visionocr.py --list LIST --out OUT [--lang ar-SA]

LIST holds one PNG path per line. OUT gets one JSON line per file: its name,
and the words of each line with their boxes in image pixels (top-left origin).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def arabic_language(request) -> str | None:
    langs, _ = request.supportedRecognitionLanguagesAndReturnError_(None)
    return next((str(l) for l in (langs or []) if str(l).lower().startswith('ar')), None)


def make_request(lang: str):
    import Vision
    request = Vision.VNRecognizeTextRequest.alloc().init()
    request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
    request.setUsesLanguageCorrection_(False)
    request.setRecognitionLanguages_([lang])
    return request


def read_page(path: str, lang: str) -> list[list[list]]:
    import Foundation
    import Vision
    import pymupdf
    pix = pymupdf.Pixmap(path)
    width, height = pix.width, pix.height
    request = make_request(lang)
    handler = Vision.VNImageRequestHandler.alloc().initWithURL_options_(Foundation.NSURL.fileURLWithPath_(path), {})
    ok, err = handler.performRequests_error_([request], None)
    if not ok:
        raise RuntimeError(str(err))
    lines: list[list[list]] = []
    for obs in request.results() or []:
        cands = obs.topCandidates_(1)
        if not cands:
            continue
        cand = cands[0]
        text = str(cand.string())
        words = []
        for m in re.finditer(r'\S+', text):
            start = len(text[:m.start()].encode('utf-16-le')) // 2
            length = len(m.group().encode('utf-16-le')) // 2
            box, _ = cand.boundingBoxForRange_error_(Foundation.NSMakeRange(start, length), None)
            if box is None:
                continue
            r = box.boundingBox()
            x0, x1 = r.origin.x * width, (r.origin.x + r.size.width) * width
            y0, y1 = (1 - r.origin.y - r.size.height) * height, (1 - r.origin.y) * height
            words.append([m.group(), round(x0, 1), round(y0, 1), round(x1, 1), round(y1, 1)])
        if words:
            lines.append(words)
    return lines


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--probe', action='store_true')
    ap.add_argument('--list')
    ap.add_argument('--out')
    ap.add_argument('--lang', default='')
    args = ap.parse_args()
    if sys.platform != 'darwin':
        return 2
    try:
        import Vision
        lang = arabic_language(Vision.VNRecognizeTextRequest.alloc().init())
    except Exception:
        return 2
    if args.probe:
        if not lang:
            return 2
        print(lang)
        return 0
    lang = args.lang or lang
    if not lang or not args.list or not args.out:
        return 2
    import objc
    with open(args.out, 'w', encoding='utf-8') as out:
        for path in Path(args.list).read_text('utf-8').splitlines():
            if not path:
                continue
            try:
                with objc.autorelease_pool():
                    lines = read_page(path, lang)
            except Exception:
                continue  # a page that fails here is simply not read by this engine
            out.write(json.dumps({'name': Path(path).stem, 'lines': lines}, ensure_ascii=False) + '\n')
            out.flush()
    return 0


if __name__ == '__main__':
    sys.exit(main())
