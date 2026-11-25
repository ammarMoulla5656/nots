# -*- coding: utf-8 -*-
"""Cooks the Masaha Horra books on this machine, two at a time, and serves a
page to watch it from any other machine on the network:

    http://<this machine>:8765/

It runs on its own: the machine that watches can be turned off. What is done
is kept in state\\state.json after each book, so a restart goes on from there.
Nothing starts until the page's Start button is pressed (or --start).

    C:\\nots_batch\\manifest.json          the books, from send_books.py
    C:\\nots_batch\\input\\0001\\...         book.pdf, book.epub, hikmah.docx
    C:\\nots_batch\\output\\<book>\\         the cooked volumes
    C:\\nots_batch\\output\\<book>\\_reports  each volume's report and added text
    C:\\nots_batch\\work\\0001\\             the OCR cache and the cook's log

The text of each volume is its Hikmah Word file, corrected by fix_docx.py
(index from library.db). When fewer than 90% of its words find their place
on the pages, the volume is cooked again with its EPUB and the better kept.
"""

import argparse
import collections
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import psutil

BASE = Path(r'C:\nots_batch')
COOK = Path(r'C:\ocr work\nots-cook-portable\cook')
PYTHON = Path(os.environ.get('LOCALAPPDATA', '')) / 'nots_cook_ssd' / 'qari_venv' / 'Scripts' / 'python.exe'
TESSERACT = r'C:\ocr work\nots-cook-portable\tools\Tesseract-OCR\tesseract.exe'
HERE = Path(__file__).resolve().parent
PLACED_FLOOR = 0.90
# The EPUB was tried whenever the Hikmah text placed under 90%, and it was worse in nearly every
# case (47 volumes, 17-25 min each); it is tried now only when the first try placed under half.
EPUB_RETRY_BELOW = 0.50
# "Redo the weak ones" cooks again what placed under this share, and what failed.
REDO_BELOW = 0.90
# Volumes of one book that need not match their PDF before the rest of the book is stopped.
MISMATCH_LIMIT = 2

sys.path.insert(0, str(COOK))


def now() -> float:
    return time.time()


def safe(name: str) -> str:
    return re.sub(r'[\\/:*?"<>|]+', ' ', name).strip().rstrip('.') or 'book'


class BrokenPdfError(RuntimeError):
    """The volume's PDF is empty or damaged at its source: cooking it again cannot help."""


class MismatchError(RuntimeError):
    """The text does not match the PDF: no page of it finds its page in the text."""


class Metrics:
    """The machine every few seconds: CPU, memory, disk, the card, and the
    CPU's temperatures and power when LibreHardwareMonitor serves them."""

    def __init__(self, every: float = 3.0):
        self.every = every
        self.latest: dict = {}
        self.history: collections.deque = collections.deque(maxlen=600)
        self.lock = threading.Lock()
        psutil.cpu_percent(percpu=True)
        threading.Thread(target=self._run, daemon=True).start()

    def _gpu(self) -> dict:
        fields = ('utilization.gpu,utilization.memory,temperature.gpu,power.draw,power.limit,'
                  'memory.used,memory.total,clocks.sm,clocks.mem,fan.speed,pstate,name')
        try:
            out = subprocess.run(['nvidia-smi', f'--query-gpu={fields}', '--format=csv,noheader,nounits'],
                                 capture_output=True, text=True, timeout=5,
                                 creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0)).stdout.strip()
            v = [x.strip() for x in out.split(',')]
            num = lambda x: float(x) if re.match(r'^-?\d+(\.\d+)?$', x) else None
            return {'util': num(v[0]), 'mem_util': num(v[1]), 'temp': num(v[2]), 'power': num(v[3]),
                    'power_limit': num(v[4]), 'vram_used': num(v[5]), 'vram_total': num(v[6]),
                    'clock_sm': num(v[7]), 'clock_mem': num(v[8]), 'fan': num(v[9]),
                    'pstate': v[10], 'name': v[11]}
        except Exception:
            return {}

    def _sensors(self) -> dict:
        """CPU temperatures, power and voltages from LibreHardwareMonitor's
        web server (localhost:8085), when it runs."""
        try:
            import urllib.request
            with urllib.request.urlopen('http://127.0.0.1:8085/data.json', timeout=2) as r:
                tree = json.loads(r.read().decode('utf-8'))
        except Exception:
            return {}
        out = {'temps': [], 'powers': [], 'volts': [], 'fans': []}
        # The sensors' kind is the group they sit in ("Temperatures", ...).
        groups = {'Temperatures': 'temps', 'Powers': 'powers', 'Voltages': 'volts', 'Fans': 'fans'}

        def walk(node, device, kind):
            text = node.get('Text', '')
            children = node.get('Children', [])
            if kind and not children and node.get('Value'):
                out[kind].append({'device': device, 'name': text, 'value': node['Value']})
            for c in children:
                if text in groups:
                    walk(c, device, groups[text])
                else:
                    walk(c, text if node.get('ImageURL') else device, kind)
        walk(tree, '', None)
        return out

    def _run(self):
        while True:
            try:
                cores = psutil.cpu_percent(percpu=True)
                vm = psutil.virtual_memory()
                du = psutil.disk_usage(str(BASE.anchor))
                freq = psutil.cpu_freq()
                sample = {
                    't': now(),
                    'cpu': round(sum(cores) / max(len(cores), 1), 1),
                    'cores': [round(c) for c in cores],
                    'freq': round(freq.current) if freq else None,
                    'ram_used': round(vm.used / 2 ** 30, 1), 'ram_total': round(vm.total / 2 ** 30, 1),
                    'disk_free': round(du.free / 2 ** 30, 1), 'disk_total': round(du.total / 2 ** 30, 1),
                    'gpu': self._gpu(),
                    'sensors': self._sensors(),
                    'procs': sum(1 for p in psutil.process_iter(['name'])
                                 if (p.info['name'] or '').lower() in ('tesseract.exe', 'python.exe')),
                }
                with self.lock:
                    self.latest = sample
                    g = sample['gpu']
                    self.history.append([round(sample['t']), sample['cpu'], g.get('util'), g.get('temp'),
                                         g.get('power'), round(vm.percent)])
            except Exception:
                pass
            time.sleep(self.every)


class Batch:
    STAGES = [  # (text in the cook's log, stage, share of the book done when it starts)
        ('text: ', 'قراءة ملف النص', 0.02),
        ("finding where the text's pages sit", 'مطابقة الصفحات', 0.04),
        ('reading ', 'بدء القراءة الضوئية', 0.06),
        ('fast Windows pass', 'قراءة Windows', 0.08),
        ('launching Qari', 'القارئ على الكرت', 0.40),
        ('OCR: ', 'قراءة Tesseract', 0.42),
        ('gap strips', 'Tesseract للمقاطع', 0.62),
        ('Qari read', 'دمج القراءات', 0.70),
        ('applying Qari', 'تحسين المقاطع', 0.78),
        ('invisible text layer', 'كتابة طبقة النص', 0.86),
        ('written ', 'حفظ الملف', 0.94),
        ('done in', 'انتهى', 1.0),
    ]

    def __init__(self, workers: int):
        self.workers = workers
        self.lock = threading.Lock()
        self.jobs = json.loads((BASE / 'manifest.json').read_text('utf-8'))
        self.by_serial = {j['serial']: j for j in self.jobs}
        self.state_path = BASE / 'state' / 'state.json'
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state = {'started': False, 'paused': False, 'started_at': None, 'active_seconds': 0.0,
                      'done': {}, 'failed': {}, 'skipped_books': {}}
        if self.state_path.exists():
            try:
                self.state.update(json.loads(self.state_path.read_text('utf-8')))
            except Exception:
                pass
        self.state.setdefault('skipped_books', {})     # hikmah book id -> why its work was stopped
        self.running: dict[str, dict] = {}
        self.events: collections.deque = collections.deque(maxlen=60)
        self.transfers: dict[str, dict] = {}      # books being sent to the site for download
        self.last_tick = None
        threading.Thread(target=self._loop, daemon=True).start()

    # ---- state ----
    def save(self):
        with self.lock:
            text = json.dumps(self.state, ensure_ascii=False)
        tmp = self.state_path.with_suffix('.part')
        tmp.write_text(text, 'utf-8')
        os.replace(tmp, self.state_path)

    def event(self, text: str):
        with self.lock:
            self.events.appendleft({'t': now(), 'text': text})

    def control(self, action: str) -> str:
        with self.lock:
            if action == 'start':
                self.state['started'] = True
                self.state['paused'] = False
                self.state['started_at'] = self.state['started_at'] or now()
            elif action == 'pause':
                self.state['paused'] = True
            elif action == 'resume':
                self.state['paused'] = False
            elif action == 'retry_failed':
                self.state['failed'] = {}
            elif action == 'retry_skipped':
                self.state['skipped_books'] = {}
            elif action == 'redo_bad':
                # The volumes that came out weak (placed under 90%) and the ones that failed are
                # cooked again, with the cook as it is now; the old files stay until the new ones
                # replace them.
                bad = [s for s, v in self.state['done'].items() if (v.get('placed') or 0) < REDO_BELOW]
                for s in bad:
                    self.state['done'].pop(s)
                final = {s: v for s, v in self.state['failed'].items() if self.pdf_broken(s)}   # a damaged PDF stays failed
                again = len(bad) + len(self.state['failed']) - len(final)
                self.state['failed'] = final
                action = f'redo_bad:{again}'
            elif re.fullmatch(r'skip_book:\d+', action):
                self.state['skipped_books'][action.split(':')[1]] = 'أُوقف يدويًّا'
            else:
                return 'unknown'
        self.save()
        self.event({'start': 'بدأ العمل', 'pause': 'إيقاف مؤقت (يكمل الكتب الجارية ثم يتوقف)',
                    'resume': 'استئناف', 'retry_failed': 'إعادة الكتب التي فشلت',
                    'retry_skipped': 'استئناف الكتب التي أُوقف العمل عليها'}.get(
            action, f'إعادة طبخ {action.split(":")[1]} مجلدًا (ضعيف أو فاشل)' if action.startswith('redo_bad:')
            else f'إيقاف العمل على الكتاب {action.split(":")[1]}'))
        return 'ok'

    # ---- the work ----
    def ready(self, job) -> bool:
        return all((BASE / job[k]).exists() for k in ('pdf', 'epub', 'docx') if job.get(k))

    def next_job(self):
        with self.lock:
            busy = set(self.running) | set(self.state['done']) | set(self.state['failed'])
            stopped = set(self.state['skipped_books'])
        for j in self.jobs:
            if j['serial'] not in busy and str(j['hikmah_book']) not in stopped and self.ready(j):
                return j
        return None

    def pdf_broken(self, serial: str) -> bool:
        p = BASE / self.by_serial[serial]['pdf']
        try:
            return p.stat().st_size < 10_000
        except OSError:
            return True

    def skipped_serials(self) -> set[str]:
        """The volumes still waiting whose book's work was stopped."""
        with self.lock:
            stopped = set(self.state['skipped_books'])
            taken = set(self.state['done']) | set(self.state['failed']) | set(self.running)
        return {j['serial'] for j in self.jobs if str(j['hikmah_book']) in stopped and j['serial'] not in taken}

    def _loop(self):
        while True:
            with self.lock:
                go = self.state['started'] and not self.state['paused']
                t = now()
                if go and self.running and self.last_tick:
                    self.state['active_seconds'] += t - self.last_tick
                self.last_tick = t
                free = self.workers - len(self.running)
            if go and free > 0:
                j = self.next_job()
                if j:
                    with self.lock:
                        self.running[j['serial']] = {'serial': j['serial'], 'stage': 'تحضير', 'share': 0.0,
                                                     'started': now(), 'source': '', 'detail': ''}
                    threading.Thread(target=self._cook_job, args=(j,), daemon=True).start()
                    continue
            time.sleep(1)

    def _set(self, serial, **kw):
        with self.lock:
            if serial in self.running:
                self.running[serial].update(kw)

    def _cook(self, job, text: Path, label: str, out_pdf: Path, log_path: Path) -> dict:
        serial = job['serial']
        cmd = [str(PYTHON), '-u', '-X', 'utf8', str(COOK / 'cook.py'), str(BASE / job['pdf']),
               *(['--text', str(text)] if text else ['--no-text']), '-o', str(out_pdf), '--no-check']
        env = dict(os.environ, NOTS_TESSERACT=TESSERACT, PYTHONIOENCODING='utf-8')
        res = {'source': label, 'placed': None, 'words': None, 'added_words': None, 'bookmarks': None,
               'seconds': None, 'error': None, 'mismatch': False}
        out_pdf.parent.mkdir(parents=True, exist_ok=True)
        t0 = now()
        with open(log_path, 'a', encoding='utf-8') as log:
            log.write(f'\n===== {dt.datetime.now():%Y-%m-%d %H:%M:%S} {label}: {" ".join(cmd)}\n')
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                 encoding='utf-8', errors='replace', cwd=str(COOK), env=env,
                                 creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            for line in p.stdout:
                log.write(line)
                s = line.strip()
                for key, stage, share in self.STAGES:
                    if key in s:
                        m = re.search(r'(\d+)/(\d+)', s)
                        frac = share
                        if m and key in ('fast Windows pass', 'OCR: ', 'gap strips'):
                            k, n = int(m.group(1)), int(m.group(2))
                            nxt = {'fast Windows pass': 0.40, 'OCR: ': 0.62, 'gap strips': 0.70}[key]
                            frac = share + (nxt - share) * k / max(n, 1)
                        self._set(serial, stage=stage, share=round(frac, 3), detail=s[:140], source=label)
                        break
                m = re.search(r'([\d,]+) words, ([\d,]+) placed on their page \(([\d.]+)%\).*?(\d+) bookmarks', s)
                if m:
                    res['words'] = int(m.group(1).replace(',', ''))
                    res['placed'] = float(m.group(3)) / 100
                    res['bookmarks'] = int(m.group(4))
                m = re.search(r'added from the PDF: ([\d,]+) words', s)
                if m:
                    res['added_words'] = int(m.group(1).replace(',', ''))
                if 'MISMATCH' in s:
                    res['mismatch'] = True
                if ('FAILED' in s or 'Traceback' in s) and not (res['error'] and 'FAILED' in res['error']):
                    res['error'] = s[:300]
            code = p.wait()
        res['seconds'] = round(now() - t0, 1)
        if code != 0 and not res['error']:
            res['error'] = f'exit code {code}'
        if not out_pdf.exists() and not res['error']:
            res['error'] = 'no output'
        return res

    def _cook_job(self, job):
        serial = job['serial']
        work = BASE / 'work' / serial
        work.mkdir(parents=True, exist_ok=True)
        log_path = work / 'cook.log'
        vol = str(job.get('volume') or '').strip()
        name = f'{serial} - {job["title"]}' + (f'_ج{vol}' if vol.isdigit() else f'_{vol}' if vol else '')
        out_dir = BASE / 'output' / safe(job['title'])
        t0 = now()
        tries = []
        try:
            if self.pdf_broken(serial):
                raise BrokenPdfError(f'ملف الـ PDF فارغ أو تالف ({(BASE / job["pdf"]).stat().st_size} بايت): '
                                     'نسخته في مصدرها معطوبة، فلا يُطبخ')
            if job.get('docx'):
                self._set(serial, stage='تصحيح ملف الحكمة', share=0.01)
                import fix_docx
                fixed = work / 'hikmah.fixed.docx'
                info = fix_docx.fix_file(str(BASE / job['docx']), str(fixed), str(BASE / 'library.db'),
                                         name=f'[ID_{job["hikmah_book"]}]_ج00', part=job.get('hikmah_part'))
                with open(log_path, 'a', encoding='utf-8') as log:
                    log.write(info + '\n')
                r = self._cook(job, fixed, 'الحكمة', work / 'hikmah' / f'{serial}.pdf', log_path)
                tries.append((r, work / 'hikmah'))
            if job.get('epub') and (not tries or tries[0][0]['error'] or (tries[0][0]['placed'] or 0) < EPUB_RETRY_BELOW):
                r = self._cook(job, BASE / job['epub'], 'EPUB', work / 'epub' / f'{serial}.pdf', log_path)
                tries.append((r, work / 'epub'))
            good = [(r, d) for r, d in tries if not r['error']]
            if not good and tries:
                # No text is usable: neither is this PDF's (al-Bihar 103: Hikmah has 8 pages of 434,
                # the EPUB is another edition), or the EPUB cannot be read at all (al-Wasail 11: "no
                # page markers"). The pages are read from their images alone, without bookmarks.
                r = self._cook(job, None, 'OCR فقط', work / 'ocr' / f'{serial}.pdf', log_path)
                tries.append((r, work / 'ocr'))
                good = [(r, d) for r, d in tries if not r['error']]
            if not good:
                if tries and all(r['mismatch'] for r, _ in tries):
                    raise MismatchError(tries[-1][0]['error'])
                raise RuntimeError(tries[-1][0]['error'] if tries else 'no text file')
            best, folder = max(good, key=lambda rd: rd[0]['placed'] or 0)
            reports = out_dir / '_reports'
            reports.mkdir(parents=True, exist_ok=True)
            final = out_dir / (safe(name) + '.pdf')
            shutil.copyfile(folder / f'{serial}.pdf', final)
            for ext in ('.report.json', '.added.txt'):
                src = folder / f'{serial}{ext}'
                if src.exists():
                    shutil.copyfile(src, reports / (safe(name) + ext))
            result = dict(best)
            result.update(output=str(final.relative_to(BASE)), total_seconds=round(now() - t0, 1),
                          tries=[{k: r[k] for k in ('source', 'placed', 'seconds', 'error')} for r, _ in tries],
                          size=final.stat().st_size, finished=now())
            with self.lock:
                self.state['done'][serial] = result
            self.event(f'انتهى {name} في {result["total_seconds"]:.0f} ث، '
                       f'موضعة {100 * (result["placed"] or 0):.1f}% ({result["source"]})')
        except Exception as e:
            mismatch = isinstance(e, MismatchError)
            if isinstance(e, BrokenPdfError):
                e = RuntimeError(str(e))     # the page shows the reason, not the class
            with self.lock:
                self.state['failed'][serial] = {'error': repr(e)[:400], 'finished': now(), 'mismatch': mismatch,
                                                'trace': traceback.format_exc()[-1500:]}
                book = str(job['hikmah_book'])
                stopped_now = False
                if mismatch and book not in self.state['skipped_books']:
                    bad = sum(1 for sv, v in self.state['failed'].items()
                              if v.get('mismatch') and str(self.by_serial[sv]['hikmah_book']) == book)
                    if bad >= MISMATCH_LIMIT:
                        self.state['skipped_books'][book] = 'نسخة الـ PDF لا تطابق نص الحكمة'
                        stopped_now = True
            self.event(f'فشل {name}: {e!r}'[:200])
            if stopped_now:
                self.event(f'أُوقف العمل على كتاب «{job["title"]}»: مجلدان لا يطابقان نص الحكمة')
        finally:
            with self.lock:
                self.running.pop(serial, None)
            self.save()

    # ---- what the page shows ----
    def failed_count(self) -> int:
        with self.lock:
            return len(self.state['failed'])

    def done_list(self) -> list[dict]:
        """The finished books, newest first, for the page's download list."""
        with self.lock:
            done = dict(self.state['done'])
        out = []
        for serial, v in done.items():
            j = self.by_serial.get(serial)
            if not j:
                continue
            out.append({'serial': serial, 'title': j['title'], 'volume': j['volume'],
                        'pages': j.get('pdf_pages') or j.get('masaha_pages'), 'size': round(v.get('size', 0) / 1e6, 1),
                        'placed': v.get('placed'), 'source': v.get('source'), 'finished': v.get('finished')})
        out.sort(key=lambda r: -(r['finished'] or 0))
        return out

    def output_of(self, serial: str):
        with self.lock:
            d = self.state['done'].get(serial)
        p = BASE / d['output'] if d else None
        return p if p and p.exists() else None

    def status(self, metrics: Metrics) -> dict:
        with self.lock:
            st = json.loads(json.dumps(self.state))
            running = [dict(r) for r in self.running.values()]
            events = list(self.events)
        pages = lambda j: j.get('pdf_pages') or j.get('masaha_pages') or 450
        done_pages = sum(pages(self.by_serial[s]) for s in st['done'] if s in self.by_serial)
        run_pages = sum(pages(self.by_serial[r['serial']]) * r['share'] for r in running)
        total_pages = sum(pages(j) for j in self.jobs)
        active = st['active_seconds']
        rate = (done_pages + run_pages) / active if active > 60 else None
        skipped = self.skipped_serials()
        left = total_pages - done_pages - run_pages - sum(pages(self.by_serial[s]) for s in list(st['failed']) + list(skipped)
                                                           if s in self.by_serial)
        eta = left / rate if rate else None
        for r in running:
            j = self.by_serial[r['serial']]
            r.update(title=j['title'], volume=j['volume'], author=j['author'], pages=pages(j),
                     elapsed=round(now() - r['started']))
        recent = sorted(st['done'].items(), key=lambda kv: -kv[1].get('finished', 0))[:25]
        placed = [v['placed'] for v in st['done'].values() if v.get('placed')]
        with metrics.lock:
            latest, history = dict(metrics.latest), list(metrics.history)
        return {
            'now': now(),
            'state': ('انتهى' if len(st['done']) + len(st['failed']) + len(skipped) >= len(self.jobs) else
                      'متوقف مؤقتاً' if st['paused'] else 'يعمل' if st['started'] else 'ينتظر البدء'),
            'started': st['started'], 'paused': st['paused'], 'started_at': st['started_at'],
            'active_seconds': round(active), 'workers': self.workers,
            'total': len(self.jobs), 'done': len(st['done']), 'failed': len(st['failed']),
            'running_count': len(running),
            'ready': sum(1 for j in self.jobs if self.ready(j)),
            'pages_total': total_pages, 'pages_done': round(done_pages + run_pages),
            'pages_per_min': round(rate * 60, 1) if rate else None,
            'eta_seconds': round(eta) if eta else None,
            'avg_seconds': round(sum(v['total_seconds'] for v in st['done'].values()) / len(st['done']), 1)
            if st['done'] else None,
            'avg_placed': round(sum(placed) / len(placed), 4) if placed else None,
            'from_hikmah': sum(1 for v in st['done'].values() if v.get('source') == 'الحكمة'),
            'from_epub': sum(1 for v in st['done'].values() if v.get('source') == 'EPUB'),
            'running': running,
            'recent': [dict(serial=s, title=self.by_serial[s]['title'], volume=self.by_serial[s]['volume'],
                            pages=pages(self.by_serial[s]), **v) for s, v in recent if s in self.by_serial],
            'skipped': len(skipped),
            'failed_list': [dict(serial=s, title=self.by_serial[s]['title'], volume=self.by_serial[s]['volume'],
                                 error=v['error']) for s, v in st['failed'].items() if s in self.by_serial]
            + [dict(serial='⏸', title=next((j['title'] for j in self.jobs if str(j['hikmah_book']) == b), b),
                    volume=f'كل المجلدات المتبقية ({sum(1 for sv in skipped if str(self.by_serial[sv]["hikmah_book"]) == b)})',
                    error=why) for b, why in st['skipped_books'].items()],
            'events': events,
            'transfers': {k: dict(v) for k, v in self.transfers.items()},
            'metrics': latest,
            'history': history,
        }

    def export_xlsx(self) -> bytes:
        import io
        import openpyxl
        from openpyxl.styles import Alignment, Font, PatternFill
        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = 'الكتب'
        ws.sheet_view.rightToLeft = True
        head = ['الرقم', 'اسم الكتاب', 'الجزء', 'المؤلف', 'التصنيف', 'الناشر الرقمي', 'امتداد الملف',
                'اسم الملف الناتج', 'المسار على الخادم', 'حجم الملف (MB)', 'عدد الصفحات', 'الحالة',
                'مصدر النص', 'نسبة موضعة الكلمات', 'الإشارات المرجعية', 'كلمات مضافة من الصفحة',
                'وقت المعالجة (ث)', 'معرف مساحة حرة', 'رابط مساحة حرة', 'معرف كتاب الحكمة',
                'معرف جزء الحكمة', 'اسم الكتاب في الحكمة', 'نسبة التطابق مع الحكمة (%)', 'العنوان في EPUB']
        ws.append(head)
        with self.lock:
            done, failed = dict(self.state['done']), dict(self.state['failed'])
            running = set(self.running)
        for j in self.jobs:
            d = done.get(j['serial'], {})
            status = ('تم' if j['serial'] in done else 'فشل' if j['serial'] in failed
                      else 'جارٍ' if j['serial'] in running
                      else 'متوقف' if str(j['hikmah_book']) in self.state['skipped_books'] else 'في الانتظار')
            out = d.get('output', '')
            ws.append([
                j['serial'], j['title'], j['volume'], j['author'], j['category'], j.get('digital_publisher', ''),
                'pdf', Path(out).name if out else '', out, round(d['size'] / 1e6, 2) if d.get('size') else None,
                j.get('pdf_pages') or j.get('masaha_pages'), status, d.get('source', ''),
                round(100 * d['placed'], 2) if d.get('placed') else None, d.get('bookmarks'), d.get('added_words'),
                d.get('total_seconds'), j.get('masaha_id'), j.get('masaha_link'), j.get('hikmah_book'),
                j.get('hikmah_part'), j.get('hikmah_title'), j.get('match_percent'), j.get('epub_title'),
            ])
        bold = Font(bold=True, color='FFFFFF')
        for c in ws[1]:
            c.font = bold
            c.fill = PatternFill('solid', fgColor='1F4E79')
            c.alignment = Alignment(horizontal='center', vertical='center', wrap_text=True)
        widths = [7, 34, 6, 30, 16, 16, 9, 40, 50, 10, 9, 10, 9, 10, 9, 10, 10, 10, 30, 9, 9, 30, 10, 34]
        for i, w in enumerate(widths, 1):
            ws.column_dimensions[openpyxl.utils.get_column_letter(i)].width = w
        ws.freeze_panes = 'C2'
        ws.auto_filter.ref = ws.dimensions
        buf = io.BytesIO()
        wb.save(buf)
        return buf.getvalue()


class Publisher:
    """Talks to the public site (nots/monitor on the Hikmah server):

    - every 4 s it asks poll.php for the commands the page's buttons left
      (start, pause, "send me book 0021");
    - every 30 s it sends the status; the list of finished books when it
      changed; the Excel file every 10 min;
    - a book that was asked for is uploaded to _dl, up to 3 at a time. The
      server only relays it: the page deletes it once downloaded, and what is
      left behind is swept after 40 min.

    It writes only inside nots/monitor on that server (its FTP root also runs
    another app). Settings in publish.json next to this file."""

    DATA = 'nots/monitor/_data'
    DL = 'nots/monitor/_dl'
    SITE = 'https://alhikmeh.org/alhawzaapp/publiclibdata/nots/monitor'

    def __init__(self, batch: Batch, metrics: Metrics, config: Path, every: int = 30):
        from concurrent.futures import ThreadPoolExecutor
        self.batch, self.metrics, self.every = batch, metrics, every
        self.cfg = json.loads(config.read_text('utf-8')) if config.exists() else None
        self.pool = ThreadPoolExecutor(3)
        self.sending: set[str] = set()
        self.lock = threading.Lock()
        self.last_xlsx = self.last_sweep = self.last_error = 0.0
        self.done_key = None
        if self.cfg:
            threading.Thread(target=self._commands_loop, daemon=True).start()
            threading.Thread(target=self._status_loop, daemon=True).start()

    def _ftp(self):
        import ftplib
        ftp = ftplib.FTP_TLS(self.cfg['host'], timeout=60)
        ftp.login(self.cfg['user'], self.cfg['password'])
        ftp.prot_p()
        return ftp

    def _put(self, ftp, folder: str, name: str, data: bytes):
        import io
        final = f'{folder}/{name}'
        ftp.storbinary(f'STOR {final}.part', io.BytesIO(data))
        try:
            ftp.delete(final)
        except Exception:
            pass
        ftp.rename(f'{final}.part', final)

    def _error(self, msg: str):
        self.batch.event(msg[:200])
        self.last_error = now()

    # ---- commands: every 4 s over HTTPS (a light request, no FTP login) ----
    def _commands_loop(self):
        import urllib.parse
        import urllib.request
        url = self.cfg.get('site', self.SITE) + '/poll.php'
        body = urllib.parse.urlencode({'key': self.cfg.get('agent_key', '')}).encode()
        failures = 0
        while True:
            try:
                req = urllib.request.Request(url, data=body, method='POST')
                with urllib.request.urlopen(req, timeout=20) as r:
                    text = r.read().decode('utf-8', 'replace')
                failures = 0
                for c in text.split():
                    self._command(c.strip())
            except Exception as e:
                failures += 1
                if failures in (3, 300):
                    self._error(f'تعذّر الاتصال بالموقع لجلب الأوامر: {e!r}')
            time.sleep(4)

    def _command(self, c: str):
        if c in ('start', 'pause', 'resume', 'retry_failed', 'retry_skipped', 'redo_bad') or re.fullmatch(r'skip_book:\d+', c):
            self.batch.control(c)
            self.batch.event(f'أمر من الموقع: {c}')
        elif re.fullmatch(r'fetch:\d{4}', c):
            serial = c[6:]
            with self.lock:
                if serial in self.sending:
                    return
                self.sending.add(serial)
            self.batch.transfers[serial] = {'state': 'uploading', 'started': now(), 'bytes': 0, 'total': 0}
            self.pool.submit(self._send_book, serial)

    def _send_book(self, serial: str):
        """Uploads one finished book to _dl for the page to hand to the browser."""
        ftp = None
        try:
            with self.batch.lock:
                done = self.batch.state['done'].get(serial)
            if not done:
                raise RuntimeError('الكتاب لم ينتهِ طبخه بعد')
            path = BASE / done['output']
            if not path.exists():
                raise RuntimeError('ملف الكتاب غير موجود على الخادم')
            total = path.stat().st_size
            tr = self.batch.transfers[serial]
            tr['total'] = total
            ftp = self._ftp()
            self._put(ftp, self.DL, f'{serial}.name', path.name.encode('utf-8'))
            final = f'{self.DL}/{serial}.pdf'

            def progress(chunk):
                tr['bytes'] += len(chunk)

            with open(path, 'rb') as f:
                ftp.storbinary(f'STOR {final}.part', f, blocksize=256 * 1024, callback=progress)
            try:
                ftp.delete(final)
            except Exception:
                pass
            ftp.rename(f'{final}.part', final)
            tr['state'] = 'ready'
            self.batch.event(f'رُفع للتنزيل: {path.name} ({total / 1e6:.1f} MB)')
        except Exception as e:
            self.batch.transfers[serial] = {'state': 'error', 'message': str(e)[:120]}
            try:
                ftp = ftp or self._ftp()
                self._put(ftp, self.DL, f'{serial}.err', str(e)[:200].encode('utf-8'))
            except Exception:
                pass
            self._error(f'فشل رفع {serial}: {e!r}')
        finally:
            with self.lock:
                self.sending.discard(serial)
            try:
                if ftp:
                    ftp.quit()
            except Exception:
                pass

    # ---- status: every 30 s over FTP ----
    def _sweep(self, ftp):
        """Deletes what the downloads left behind in _dl after 40 minutes."""
        try:
            entries = list(ftp.mlsd(self.DL, facts=['modify', 'type']))
        except Exception:
            return
        for name, facts in entries:
            if facts.get('type') != 'file' or name == '.htaccess':
                continue
            try:
                age = time.time() - dt.datetime.strptime(facts['modify'][:14], '%Y%m%d%H%M%S').replace(
                    tzinfo=dt.timezone.utc).timestamp()
            except Exception:
                continue
            if age > 40 * 60:
                try:
                    ftp.delete(f'{self.DL}/{name}')
                except Exception:
                    pass

    def _status_loop(self):
        while True:
            t = now()
            try:
                ftp = self._ftp()
                status = self.batch.status(self.metrics)
                self._put(ftp, self.DATA, 'status.txt', json.dumps(status, ensure_ascii=False).encode('utf-8'))
                done = self.batch.done_list()
                key = (len(done), self.batch.failed_count())
                if key != self.done_key:
                    self._put(ftp, self.DATA, 'done.txt', json.dumps(done, ensure_ascii=False).encode('utf-8'))
                    self.done_key = key
                if t - self.last_xlsx >= 600:
                    self._put(ftp, self.DATA, 'books.xlsx', self.batch.export_xlsx())
                    self.last_xlsx = t
                if t - self.last_sweep >= 300:
                    self._sweep(ftp)
                    self.last_sweep = t
                ftp.quit()
            except Exception as e:
                if t - self.last_error > 600:
                    self._error(f'تعذّر الإرسال إلى الموقع: {e!r}')
            time.sleep(max(5.0, self.every - (now() - t)))


def serve(batch: Batch, metrics: Metrics, port: int):
    page = (HERE / 'dashboard.html').read_bytes

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, body: bytes, kind: str, extra=None):
            self.send_response(code)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path in ('/', '/index.html'):
                self.send(200, page(), 'text/html; charset=utf-8')
            elif self.path.startswith('/api/status'):
                self.send(200, json.dumps(batch.status(metrics), ensure_ascii=False).encode('utf-8'),
                          'application/json; charset=utf-8')
            elif self.path.startswith('/api/export.xlsx'):
                name = f'masaha_books_{dt.datetime.now():%Y%m%d_%H%M}.xlsx'
                self.send(200, batch.export_xlsx(),
                          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                          {'Content-Disposition': f'attachment; filename="{name}"'})
            elif self.path.startswith('/api/done'):
                self.send(200, json.dumps(batch.done_list(), ensure_ascii=False).encode('utf-8'),
                          'application/json; charset=utf-8')
            elif self.path.startswith('/api/download/'):
                from urllib.parse import quote
                serial = re.sub(r'\D', '', self.path.rsplit('/', 1)[-1])[:4]
                p = batch.output_of(serial)
                if not p:
                    self.send(404, 'الكتاب لم ينتهِ بعد'.encode('utf-8'), 'text/plain; charset=utf-8')
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'application/pdf')
                self.send_header('Content-Length', str(p.stat().st_size))
                self.send_header('Content-Disposition', "attachment; filename*=UTF-8''" + quote(p.name))
                self.end_headers()
                with open(p, 'rb') as f:
                    shutil.copyfileobj(f, self.wfile, 1 << 20)
            elif self.path.startswith('/api/log/'):
                serial = re.sub(r'\D', '', self.path.rsplit('/', 1)[-1])[:4]
                p = BASE / 'work' / serial / 'cook.log'
                body = p.read_bytes()[-20000:] if p.exists() else b''
                self.send(200, body, 'text/plain; charset=utf-8')
            else:
                self.send(404, b'not found', 'text/plain')

        def do_POST(self):
            m = re.match(r'^/api/(start|pause|resume|retry_failed|retry_skipped|redo_bad|skip_book:\d+)$', self.path)
            if not m:
                self.send(404, b'not found', 'text/plain')
                return
            self.send(200, batch.control(m.group(1)).encode(), 'text/plain')

    ThreadingHTTPServer(('0.0.0.0', port), Handler).serve_forever()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--workers', type=int, default=2, help='books cooked at once')
    ap.add_argument('--port', type=int, default=8765)
    ap.add_argument('--start', action='store_true', help='start without waiting for the button')
    a = ap.parse_args()
    metrics = Metrics()
    batch = Batch(a.workers)
    if a.start:
        batch.control('start')
    Publisher(batch, metrics, HERE / 'publish.json')
    print(f'serving http://0.0.0.0:{a.port}/ ({len(batch.jobs)} books)', flush=True)
    serve(batch, metrics, a.port)


if __name__ == '__main__':
    main()
