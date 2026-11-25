"""Cooks a folder of books, and picks up where it stopped: run it again after
a power cut and only the unfinished books are cooked. Their OCR is kept in the
output folder, so an unfinished book loses at most its last minute of reading.

    python batch.py BOOKS OUT [--jobs 2] [--slice 0,1/3]

BOOKS holds each PDF with its Word file, or a folder per book. --slice splits
the books between machines: 0,1/3 here and 2/3 on a machine half as fast.
A book that fails twice is left for last and listed in OUT/batch.log.
"""

import argparse
import concurrent.futures
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from nots_cook.cli import find_source  # noqa: E402

ATTEMPTS = 2


def books_in(folder: Path) -> list[Path]:
    return sorted(p for p in folder.rglob('*.pdf') if '.nots.' not in p.name)


def in_slice(index: int, wanted: set[int], parts: int) -> bool:
    return index % parts in wanted


def parse_slice(text: str) -> tuple[set[int], int]:
    wanted, parts = text.split('/')
    return {int(n) for n in wanted.split(',')}, int(parts)


class Log:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()

    def __call__(self, text: str):
        line = f'{time.strftime("%Y-%m-%d %H:%M:%S")} {text}'
        with self.lock:
            print(line, flush=True)
            with open(self.path, 'a', encoding='utf-8') as f:
                f.write(line + '\n')


def cook(pdf: Path, out: Path, workers: int, strong: str, log: Log) -> bool:
    folder = out / pdf.stem
    folder.mkdir(parents=True, exist_ok=True)
    result = folder / f'{pdf.stem}.nots.pdf'
    report = folder / f'{pdf.stem}.nots.report.json'
    if report.exists():
        return True
    cmd = [sys.executable, '-X', 'utf8', '-u', str(HERE / 'cook.py'), str(pdf), '-o', str(result),
           '--ocr', 'auto', '--strong', strong, '--workers', str(workers)]
    source = find_source(pdf)
    cmd += ['--text', str(source)] if source else ['--no-text']
    for attempt in range(1, ATTEMPTS + 1):
        started = time.time()
        log(f'start {pdf.name}' + ('' if source else ' (no text file)'))
        with open(folder / 'cook.log', 'a', encoding='utf-8') as f:
            code = subprocess.call(cmd, stdout=f, stderr=subprocess.STDOUT, cwd=str(folder),
                                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        if code == 0 and report.exists():
            log(f'done  {pdf.name} in {(time.time() - started) / 60:.1f} min')
            return True
        log(f'FAILED {pdf.name} (exit code {code}, attempt {attempt}/{ATTEMPTS})')
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('books', type=Path)
    ap.add_argument('out', type=Path)
    ap.add_argument('--jobs', type=int, default=2, help='books at the same time')
    ap.add_argument('--workers', type=int, default=8, help='CPU workers of each book')
    ap.add_argument('--strong', choices=['auto', 'on', 'off'], default='auto', help='Qari')
    ap.add_argument('--slice', default='0/1', help='this machine\'s share, as 0,1/3')
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    log = Log(args.out / 'batch.log')
    wanted, parts = parse_slice(args.slice)
    books = [b for i, b in enumerate(books_in(args.books)) if in_slice(i, wanted, parts)]
    log(f'{len(books)} books in this slice, {args.jobs} at a time')
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        done = list(pool.map(lambda b: cook(b, args.out, args.workers, args.strong, log), books))
    log(f'finished: {sum(done)} cooked, {len(done) - sum(done)} failed')
    return 0 if all(done) else 1


if __name__ == '__main__':
    sys.exit(main())
