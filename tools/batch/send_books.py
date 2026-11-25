# -*- coding: utf-8 -*-
"""Sends the Masaha Horra books that match Hikmah to the cooking machine.

Reads the mapping (تقرير_الكتب_المتشابهة_مساحة_حرة_والمصدر.xlsx): each volume's
PDF and EPUB in كتب_مساحة_حرة_المتشابهة and its Hikmah volume's Word file in
كتب_المكتبة_docx. Writes manifest.json and uploads, in the order the books
will be cooked, over several SSH connections at once (one carries ~15 MB/s):

    C:\\nots_batch\\manifest.json
    C:\\nots_batch\\library.db                (Hikmah's index, for fix_docx)
    C:\\nots_batch\\input\\0001\\book.pdf, book.epub, hikmah.docx

A file is written as .part and renamed when whole, so the server never cooks
a half-sent book. Run it again to resume: files already there whole are
skipped. The password is asked for, or taken from NOTS_PW; it is not kept.

    python send_books.py [--host 192.168.68.103] [--user ammar] [--connections 6]
"""

import argparse
import getpass
import json
import os
import queue
import re
import sys
import threading
import time
import zipfile
from pathlib import Path

import openpyxl
import paramiko
import pymupdf

ROOT = Path(__file__).resolve().parents[2]
MAPPING = ROOT / 'تقرير_الكتب_المتشابهة_مساحة_حرة_والمصدر.xlsx'
REMOTE = 'C:/nots_batch'


def epub_meta(path: Path) -> dict:
    try:
        z = zipfile.ZipFile(path)
        opf = next(n for n in z.namelist() if n.endswith('.opf'))
        x = z.read(opf).decode('utf-8', 'replace')
        return {k: ' '.join(v.split()) for k, v in re.findall(r'<dc:(\w+)[^>]*>([^<]*)</dc:\1>', x)}
    except Exception:
        return {}


def local(p: str) -> Path:
    """A path from the sheet (written on this machine as d:\\01_Projects\\...)."""
    p = Path(p)
    if p.exists():
        return p
    parts = p.parts
    for i, part in enumerate(parts):
        if part.lower() == 'nots':
            q = ROOT.joinpath(*parts[i + 1:])
            if q.exists():
                return q
    return p


def manifest() -> list[dict]:
    ws = openpyxl.load_workbook(MAPPING, read_only=True).worksheets[0]
    rows = list(ws.iter_rows(values_only=True))
    head = rows[0]
    jobs = []
    for r in rows[1:]:
        row = dict(zip(head, r))
        if row.get('حالة PDF') != 'متوفر (مساحة حرة)':
            continue
        serial = str(row['الرقم التسلسلي']).zfill(4)
        pdf = local(row['مسار PDF المعزول المرقم'])
        epub = local(row['مسار EPUB المعزول المرقم'])
        docx = local(row['مسار DOCX المصدر']) if row.get('مسار DOCX المصدر') else None
        if not pdf.exists():
            continue
        meta = epub_meta(epub) if epub.exists() else {}
        try:  # the sheet's page count is the text's, not the scan's (al-Salat: 154 against 393)
            pdf_pages = pymupdf.open(pdf).page_count
        except Exception:
            pdf_pages = row.get('صفحات مساحة حرة')
        title = str(row['اسم الكتاب (مساحة حرة)']).strip()
        volume = str(row['الجزء'] or '').strip()
        jobs.append({
            'serial': serial,
            'title': title,
            'volume': volume,
            'author': row.get('المؤلف') or meta.get('creator') or '',
            'category': row.get('التصنيف') or '',
            'masaha_id': row.get('معرف مساحة حرة (ID)'),
            'masaha_link': row.get('رابط مساحة حرة') or '',
            'hikmah_book': row.get('معرف كتاب المصدر'),
            'hikmah_part': row.get('معرف جزء المصدر'),
            'hikmah_title': row.get('اسم الكتاب (المصدر)') or '',
            'match_percent': row.get('نسبة التطابق (%)'),
            'masaha_pages': row.get('صفحات مساحة حرة'),
            'pdf_pages': pdf_pages,
            'hikmah_pages': row.get('صفحات المصدر'),
            'epub_title': meta.get('title', ''),
            'epub_author': meta.get('creator', ''),
            'digital_publisher': meta.get('publisher', ''),
            'pdf_name': pdf.name,
            'local': {'pdf': str(pdf), 'epub': str(epub) if epub.exists() else None,
                      'docx': str(docx) if docx and docx.exists() else None},
            'pdf': f'input/{serial}/book.pdf',
            'epub': f'input/{serial}/book.epub' if epub.exists() else None,
            'docx': f'input/{serial}/hikmah.docx' if docx and docx.exists() else None,
            'size': pdf.stat().st_size,
        })
    jobs.sort(key=lambda j: j['serial'])
    return jobs


def connect(host, user, pw):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username=user, password=pw, timeout=20, allow_agent=False, look_for_keys=False)
    t = c.get_transport()
    t.window_size = 2 ** 30
    t.packetizer.REKEY_BYTES = 2 ** 40
    t.packetizer.REKEY_PACKETS = 2 ** 40
    return c, c.open_sftp()


def ensure_dir(s, path):
    cur = ''
    for part in path.strip('/').split('/'):
        cur = f'{cur}/{part}' if cur else part
        try:
            s.stat(cur)
        except IOError:
            try:
                s.mkdir(cur)
            except IOError:
                pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--host', default='192.168.68.103')
    ap.add_argument('--user', default='ammar')
    ap.add_argument('--connections', type=int, default=6)
    ap.add_argument('--manifest-only', action='store_true')
    a = ap.parse_args()
    pw = os.environ.get('NOTS_PW') or getpass.getpass(f'{a.user}@{a.host} password: ')

    jobs = manifest()
    print(f'{len(jobs)} volumes; {sum(1 for j in jobs if j["docx"])} with their Hikmah Word file; '
          f'{sum(j["size"] for j in jobs) / 1e9:.1f} GB of PDF', flush=True)
    c, s = connect(a.host, a.user, pw)
    ensure_dir(s, REMOTE + '/input')
    with s.open(REMOTE + '/manifest.json.part', 'w') as f:
        f.write(json.dumps([{k: v for k, v in j.items() if k != 'local'} for j in jobs],
                           ensure_ascii=False, indent=1).encode('utf-8'))
    try:
        s.remove(REMOTE + '/manifest.json')
    except IOError:
        pass
    s.rename(REMOTE + '/manifest.json.part', REMOTE + '/manifest.json')
    print('manifest.json sent', flush=True)
    if a.manifest_only:
        return

    files = [(str(ROOT / 'library.db'), REMOTE + '/library.db')]
    for j in jobs:
        for kind in ('pdf', 'epub', 'docx'):
            if j[kind]:
                files.append((j['local'][kind], f'{REMOTE}/{j[kind]}'))
    for j in jobs:
        ensure_dir(s, f'{REMOTE}/input/{j["serial"]}')
    s.close()
    c.close()

    q: queue.Queue = queue.Queue()
    for item in files:
        q.put(item)
    total = sum(os.path.getsize(l) for l, _ in files)
    sent = [0, 0, 0]   # bytes, files, skipped
    lock = threading.Lock()
    t0 = time.time()

    def worker():
        c, s = connect(a.host, a.user, pw)
        while True:
            try:
                src, dst = q.get_nowait()
            except queue.Empty:
                break
            size = os.path.getsize(src)
            try:
                if s.stat(dst).st_size == size:
                    with lock:
                        sent[0] += size
                        sent[2] += 1
                    continue
            except IOError:
                pass
            for attempt in range(5):
                try:
                    s.put(src, dst + '.part')
                    try:
                        s.remove(dst)
                    except IOError:
                        pass
                    s.rename(dst + '.part', dst)
                    break
                except Exception as e:
                    print(f'  retry {attempt + 1} {dst}: {e!r}', flush=True)
                    time.sleep(3)
                    try:
                        s.close(); c.close()
                    except Exception:
                        pass
                    c, s = connect(a.host, a.user, pw)
            with lock:
                sent[0] += size
                sent[1] += 1
        s.close()
        c.close()

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(a.connections)]
    for t in threads:
        t.start()
    while any(t.is_alive() for t in threads):
        time.sleep(10)
        dt = time.time() - t0
        with lock:
            b, n, k = sent
        rate = b / max(dt, 1) / 1e6
        left = (total - b) / 1e6 / max(rate, 0.1)
        print(f'  {b / 1e9:.2f}/{total / 1e9:.2f} GB, {n} files sent, {k} already there, '
              f'{rate:.0f} MB/s, about {left / 60:.0f} min left', flush=True)
    print(f'done: {sent[1]} files sent, {sent[2]} already there, {time.time() - t0:.0f}s', flush=True)


if __name__ == '__main__':
    main()
