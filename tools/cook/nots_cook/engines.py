"""The OCR engines found on this machine, and merging what they read.

Nothing is downloaded or installed: the tool uses what the machine has, the
strongest first.

- Tesseract, the program (with the Arabic model next to this tool): reads
  diacritics and says how sure it is of each word.
- Windows' own OCR, when Arabic is installed: fast, no diacritics, and it
  makes different mistakes than Tesseract.
- MuPDF's built-in Tesseract, when there is nothing else.

Two engines together read more than either: on the Amali scan each read
about 94% of the letters right, and between them 98.5%. [merge] keeps
Tesseract's words where they agree (they carry the diacritics) and, where
they differ, the reading the book's own vocabulary knows.
"""

from __future__ import annotations

import atexit
import collections
import contextlib
import csv
try:  # the same algorithm compiled: identical results, ~11x faster
    import cydifflib as difflib
except ImportError:
    import difflib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from concurrent.futures import FIRST_COMPLETED, ProcessPoolExecutor, ThreadPoolExecutor, as_completed, wait
from dataclasses import dataclass
from pathlib import Path

import pymupdf

HERE = Path(__file__).resolve().parent
BIDI_MARKS = dict.fromkeys((0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x061C), None)
FOLD = str.maketrans({'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا', 'ى': 'ي', 'ئ': 'ي', 'ؤ': 'و', 'ة': 'ه'})

# Run worker processes at full normal priority without console windows so
# CPU and GPU both reach 100% utilization.
_NO_WINDOW = getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000)
_SUBPROC_FLAGS = _NO_WINDOW if sys.platform == 'win32' else 0


def default_workers() -> int:
    """Uses all logical CPU cores (100% CPU capacity) by default."""
    return max(2, os.cpu_count() or 4)


@dataclass(eq=False)
class OcrWord:
    text: str
    box: tuple[float, float, float, float]  # points, top-left origin
    conf: float = -1.0                       # 0-100, -1 when the engine does not say
    line: int = 0                            # line number on the page, in reading order
    both: bool = False                       # two engines read the same letters

    def pack(self) -> list:
        return [self.text, *[round(v, 1) for v in self.box], round(self.conf, 1), self.line]

    @staticmethod
    def unpack(v: list) -> 'OcrWord':
        return OcrWord(v[0], tuple(v[1:5]), v[5], v[6])


def letters(s: str) -> str:
    """The letters of a word (no marks, digits or punctuation), folded so
    spelling variants of hamza and final forms compare equal."""
    return ''.join(c for c in s if unicodedata.category(c).startswith('L') and c != 'ـ').translate(FOLD)


# ---- finding the engines & hardware ----

_GPU_CACHE: tuple[bool, dict | None] = (False, None)


def ssd_buffer_dir() -> Path:
    """Returns a fast buffer directory physically located on the C: SSD
    (never on D: or G: mechanical HDDs) for RAM-overflow page buffering
    and SSD -> RAM -> GPU VRAM model streaming."""
    if sys.platform == 'darwin':
        p = Path.home() / 'Library/Caches/nots_cook_ssd/page_buffer'
    else:
        local_app = os.environ.get('LOCALAPPDATA') or str(Path.home() / 'AppData/Local')
        p = Path(local_app) / 'nots_cook_ssd' / 'page_buffer'
    p.mkdir(parents=True, exist_ok=True)
    return p


def system_ram_info() -> dict[str, int]:
    """Returns System RAM status in MiB: {'total_mb', 'avail_mb', 'used_pct'}."""
    if sys.platform == 'win32':
        import ctypes

        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ('dwLength', ctypes.c_ulong),
                ('dwMemoryLoad', ctypes.c_ulong),
                ('ullTotalPhys', ctypes.c_ulonglong),
                ('ullAvailPhys', ctypes.c_ulonglong),
                ('ullTotalPageFile', ctypes.c_ulonglong),
                ('ullAvailPageFile', ctypes.c_ulonglong),
                ('ullTotalVirtual', ctypes.c_ulonglong),
                ('ullAvailVirtual', ctypes.c_ulonglong),
                ('ullAvailExtendedVirtual', ctypes.c_ulonglong),
            ]

        stat = MEMORYSTATUSEX()
        stat.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat)):
            return {
                'total_mb': int(stat.ullTotalPhys // (1024 * 1024)),
                'avail_mb': int(stat.ullAvailPhys // (1024 * 1024)),
                'used_pct': int(stat.dwMemoryLoad),
            }
    if sys.platform == 'darwin':
        try:
            import psutil
            m = psutil.virtual_memory()
            return {'total_mb': int(m.total // 2**20), 'avail_mb': int(m.available // 2**20),
                    'used_pct': int(m.percent)}
        except Exception:
            pass
    return {'total_mb': 16384, 'avail_mb': 8192, 'used_pct': 50}


def nvidia_gpu_info() -> dict | None:
    """Detects an NVIDIA GPU (RTX or GTX) via nvidia-smi, returning its name,
    VRAM in MiB and driver version, or None."""
    global _GPU_CACHE
    if _GPU_CACHE[0]:
        return _GPU_CACHE[1]
    smi = shutil.which('nvidia-smi') or r'C:\Windows\System32\nvidia-smi.exe'
    if not smi or not Path(smi).exists():
        _GPU_CACHE = (True, None)
        return None
    try:
        r = subprocess.run(
            [smi, '--query-gpu=name,memory.total,driver_version', '--format=csv,noheader,nounits'],
            capture_output=True, text=True, timeout=10, creationflags=_NO_WINDOW if sys.platform == 'win32' else 0)
        if r.returncode == 0 and r.stdout.strip():
            first = r.stdout.strip().splitlines()[0]
            parts = [p.strip() for p in first.split(',')]
            if len(parts) >= 2:
                info = {
                    'name': parts[0],
                    'vram_mb': int(float(parts[1])) if parts[1].replace('.', '').isdigit() else 0,
                    'driver': parts[2] if len(parts) > 2 else '',
                }
                _GPU_CACHE = (True, info)
                return info
    except Exception:
        pass
    _GPU_CACHE = (True, None)
    return None


def find_tesseract() -> str | None:
    env = os.environ.get('NOTS_TESSERACT')
    candidates = [env, shutil.which('tesseract'),
                  r'C:\Program Files\Tesseract-OCR\tesseract.exe',
                  r'C:\Program Files (x86)\Tesseract-OCR\tesseract.exe',
                  str(Path.home() / 'AppData/Local/Programs/Tesseract-OCR/tesseract.exe'),
                  '/usr/bin/tesseract', '/usr/local/bin/tesseract', '/opt/homebrew/bin/tesseract']
    for c in candidates:
        if c and Path(c).exists():
            return c
    return None


def windows_ocr_language() -> str | None:
    """The Arabic language Windows' OCR can read here, or None."""
    if sys.platform != 'win32':
        return None
    script = ("[void][Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime];"
              "[Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | % { $_.LanguageTag }")
    try:
        r = subprocess.run(['powershell', '-NoProfile', '-Command', script],
                           capture_output=True, text=True, timeout=60, creationflags=_SUBPROC_FLAGS)
    except Exception:
        return None
    tags = r.stdout.split()
    return next((t for t in tags if t.lower().startswith('ar')), None)


_APPLE_CACHE: tuple[bool, str | None] = (False, None)


def apple_ocr_language() -> str | None:
    """The Arabic language Apple's Vision OCR reads here (macOS with pyobjc), or None."""
    global _APPLE_CACHE
    if _APPLE_CACHE[0]:
        return _APPLE_CACHE[1]
    tag = None
    if sys.platform == 'darwin':
        try:
            r = subprocess.run([sys.executable, str(HERE / 'visionocr.py'), '--probe'],
                               capture_output=True, text=True, timeout=120)
            if r.returncode == 0:
                tag = r.stdout.strip() or None
        except Exception:
            pass
    _APPLE_CACHE = (True, tag)
    return tag


QARI_MODEL = 'models--NAMAA-Space--Qari-OCR-0.2.2.1-VL-2B-Instruct'
QARI_BASE = 'models--Qwen--Qwen2-VL-2B-Instruct'
QARI_ATTEMPTS = 3


_QARI_CACHE: tuple[bool, str | None] = (False, None)


def find_qari() -> str | None:
    """A Python that can run Qari-OCR, the Arabic vision model: its model
    files must already be on this machine and so must its libraries. This
    is never installed or downloaded here: setup_gpu.py does that, when asked
    to. Prefers a CUDA-enabled Python environment when multiple exist."""
    global _QARI_CACHE
    if _QARI_CACHE[0]:
        return _QARI_CACHE[1]
    hub = Path(os.environ.get('HF_HOME', Path.home() / '.cache/huggingface')) / 'hub'
    if not ((hub / QARI_MODEL).exists() and (hub / QARI_BASE).exists()):
        _QARI_CACHE = (True, None)
        return None
    local_app = os.environ.get('LOCALAPPDATA') or str(Path.home() / 'AppData/Local')
    candidates = [os.environ.get('NOTS_QARI_PYTHON'),
                  str(Path(local_app) / 'nots_cook_ssd/qari_venv/Scripts/python.exe'), sys.executable]
    for root in (Path.home(), Path('D:/01_Projects/desktop'), Path('C:/')):
        candidates.append(str(root / 'arabic-ocr-test/venv/Scripts/python.exe'))
        candidates.append(str(root / 'arabic-ocr-test/venv/bin/python'))
    cpu_fallback = None
    seen = set()
    probe = ('import importlib.util as u; '
             'assert all(u.find_spec(m) for m in ("torch","peft","transformers","qwen_vl_utils")); '
             'import torch; print(int(torch.cuda.is_available()))')
    for c in candidates:
        if not c or not Path(c).exists():
            continue
        norm = str(Path(c).resolve())
        if norm in seen:
            continue
        seen.add(norm)
        # Quick pre-check: skip spawning python if site-packages clearly lacks peft/qwen_vl_utils
        site_win = Path(norm).parent.parent / 'Lib' / 'site-packages'
        if site_win.exists() and not (site_win / 'peft').exists():
            continue
        if cpu_fallback is not None and site_win.exists():
            # We already have a working CPU venv; only probe another venv if it has CUDA DLLs
            if not (site_win / 'torch' / 'lib' / 'torch_cuda.dll').exists():
                continue
        try:
            r = subprocess.run([c, '-c', probe],
                               capture_output=True, text=True, timeout=60, creationflags=_SUBPROC_FLAGS)
        except Exception:
            continue
        if r.returncode == 0:
            if r.stdout.strip().endswith('1'):
                _QARI_CACHE = (True, c + '|gpu')
                return _QARI_CACHE[1]
            if cpu_fallback is None:
                cpu_fallback = c + '|cpu'
    _QARI_CACHE = (True, cpu_fallback)
    return cpu_fallback


@contextlib.contextmanager
def gpu_turn():
    """One Qari at a time, between the books of a batch: two models do not fit
    in the VRAM of most cards, and each would fall back to streaming from RAM.
    The system drops the lock when its process ends, however it ends."""
    with open(ssd_buffer_dir() / 'gpu.lock', 'a+b') as f:
        while not _try_lock(f):
            time.sleep(2)
        yield


def _try_lock(f) -> bool:
    try:
        if sys.platform == 'win32':
            import msvcrt
            f.seek(0)
            msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


class QariServer:
    """One Qari worker kept loaded for the whole book (qari_worker.py
    --serve). It holds the GPU turn while it lives, so it starts only when
    no other book has the card."""

    def __init__(self, python: str, log=None):
        self.python, self.log = python, log
        self.lock = threading.Lock()
        self.jobs = 0
        self.last_lines: collections.deque[str] = collections.deque(maxlen=6)
        self.p = None
        self.turn = open(ssd_buffer_dir() / 'gpu.lock', 'a+b')
        if not _try_lock(self.turn):
            self.turn.close()
            self.turn = None
            return
        self.dir = Path(tempfile.mkdtemp(prefix='nots_qsrv_', dir=str(ssd_buffer_dir())))
        flags = _SUBPROC_FLAGS | (0x00008000 if sys.platform == 'win32' else 0)
        env = dict(os.environ, NOTS_QARI_THREADS='2')
        self.p = subprocess.Popen(
            [python, str(HERE / 'qari_worker.py'), '--serve', str(self.dir),
             '--parent', str(os.getpid()), '--tokens', '700'],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
            encoding='utf-8', errors='replace', creationflags=flags, env=env)
        threading.Thread(target=_relay_stderr, args=(self.p, self.last_lines, log), daemon=True).start()

    def alive(self) -> bool:
        return self.p is not None and self.p.poll() is None

    def run(self, todo, cached, lock, on_read) -> tuple[int, int | None, list[str]]:
        with self.lock:
            self.jobs += 1
            text, names = _job_list(todo)
            job = self.dir / f'job{self.jobs:04d}.txt'
            tmp = job.with_suffix('.tmp')
            tmp.write_text(text, 'utf-8')
            tmp.replace(job)
            done = job.with_suffix('.done')
            seen = _follow(job.with_suffix('.jsonl'), names, cached, lock, on_read,
                           lambda: done.exists() or not self.alive() or _QARI_CANCEL.is_set())
            code = 0 if done.exists() else (self.p.returncode if self.p else None)
            return seen, code, list(self.last_lines)

    def close(self, now: bool = False):
        if self.p is not None:
            try:
                if now:
                    raise TimeoutError  # in the middle of a batch: no use waiting for it
                (self.dir / 'stop').touch()
                self.p.wait(timeout=15)
            except Exception:
                self.p.kill()
                try:
                    self.p.wait(timeout=10)
                except Exception:
                    pass
            self.p = None
            shutil.rmtree(self.dir, ignore_errors=True)
        if self.turn:
            self.turn.close()  # closing the file drops the lock
            self.turn = None


_SERVER: QariServer | None = None
# Set when the book no longer waits for Qari (see cancel_qari).
_QARI_CANCEL = threading.Event()


def start_qari_server(python: str, log=None) -> bool:
    """Starts loading Qari now, for qari_read to use later. False when
    another book holds the GPU (qari_read then waits its turn as before)."""
    global _SERVER
    _QARI_CANCEL.clear()
    if _SERVER is None:
        _SERVER = QariServer(python, log)
        atexit.register(stop_qari_server)
    return _SERVER.alive()


def stop_qari_server(now: bool = False):
    global _SERVER
    if _SERVER is not None:
        _SERVER.close(now)
        _SERVER = None


def cancel_qari():
    """Stops Qari where it is: what it has read stays in the cache and is
    used, the rest keeps the CPU engines' reading. On an old CPU Qari reads a
    long passage in 10 s and more; a book must not wait 15 minutes on the
    GPU for the few words it changes (al-Mizan 6: the CPU was done at 145 s,
    Qari at 970 s)."""
    _QARI_CANCEL.set()
    stop_qari_server(now=True)


def qari_cancelled() -> bool:
    return _QARI_CANCEL.is_set()


def qari_read(python: str, images: dict[str, str | tuple[str, int]], cached: dict[str, str],
              on_save, log=None, lock=None) -> None:
    """Reads [images] (key -> image file or (image file, max_tokens)) with
    Qari-OCR on the GPU/CPU into [cached], which [lock] guards from other
    threads. A worker that dies is started again on what is left as long as
    it gets something read; what it could not read is reported in the log."""
    lock = lock or threading.Lock()
    total = len([k for k in images if k not in cached])
    if not total:
        return
    done = 0
    for attempt in range(QARI_ATTEMPTS):
        todo = {k: v for k, v in images.items() if k not in cached}
        if not todo or _QARI_CANCEL.is_set():
            return
        server = _SERVER
        if server is not None and not server.alive():
            stop_qari_server()  # drops its GPU turn for the worker below
            server = None
        if server is not None and server.python == python:
            read, code, last_lines = server.run(todo, cached, lock,
                                                lambda n: on_save(done + n, total))
        else:
            # Another book on the card (books cooked two at a time): wait for
            # it only until this book no longer wants Qari.
            with open(ssd_buffer_dir() / 'gpu.lock', 'a+b') as turn:
                while not _try_lock(turn):
                    if _QARI_CANCEL.is_set():
                        return
                    time.sleep(1)
                read, code, last_lines = _qari_worker(python, todo, cached, lock, log,
                                                      lambda n: on_save(done + n, total))
        done += read
        if (code == 0 and read == len(todo)) or _QARI_CANCEL.is_set():
            return
        if log:
            log(f'  [GPU Qari] WARNING: the worker stopped (exit code {code}) after '
                f'{done}/{total} passages')
            for line in last_lines:
                log(f'  [GPU Qari]   {line}')
        if not read:
            break
    if log and done < total:
        log(f'  [GPU Qari] WARNING: {total - done} passages were not read by Qari; '
            'the CPU OCR reading stays for them')


def _qari_worker(python: str, todo: dict[str, str | tuple[str, int]], cached: dict[str, str],
                 lock, log, on_read) -> tuple[int, int | None, list[str]]:
    """One run of the worker on [todo]: how many passages it read, its exit
    code and the last lines of its error output."""
    with tempfile.TemporaryDirectory(prefix='nots_qari_', dir=str(ssd_buffer_dir())) as d:
        lst = Path(d) / 'list.txt'
        text, names = _job_list(todo)
        lst.write_text(text, 'utf-8')
        out = Path(d) / 'out.jsonl'
        # ABOVE_NORMAL priority: Tesseract keeps every core at 100%, and the
        # process feeding the GPU must not wait behind it or the GPU idles.
        flags = _SUBPROC_FLAGS | (0x00008000 if sys.platform == 'win32' else 0)
        env = dict(os.environ, NOTS_QARI_THREADS='2')
        p = subprocess.Popen([python, str(HERE / 'qari_worker.py'), str(lst), str(out), '--tokens', '700'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                             text=True, encoding='utf-8', errors='replace',
                             creationflags=flags, env=env)
        last_lines: collections.deque[str] = collections.deque(maxlen=6)
        reader_thread = threading.Thread(target=_relay_stderr, args=(p, last_lines, log), daemon=True)
        reader_thread.start()
        try:
            seen = _follow(out, names, cached, lock, on_read,
                           lambda: p.poll() is not None or _QARI_CANCEL.is_set())
        finally:
            if p.poll() is None:
                p.kill()
                p.wait(timeout=10)
        reader_thread.join(timeout=5)
        return seen, p.returncode, list(last_lines)


def _job_list(todo: dict[str, str | tuple[str, int]]) -> tuple[str, dict[str, str]]:
    """The worker's list of [todo] (image, tab, token limit per line), and
    which key each image's name stands for."""
    lines_out = []
    names = {}
    for k, v in todo.items():
        if isinstance(v, tuple):
            png, max_tok = v
            lines_out.append(f'{png}\t{max_tok}')
        else:
            png = v
            lines_out.append(png)
        names[Path(png).stem] = k
    return '\n'.join(lines_out), names


def _relay_stderr(p, last_lines, log):
    if not p.stderr:
        return
    for line in p.stderr:
        s = line.strip()
        if s:
            last_lines.append(s[:300])
        if s and log and ('loaded on' in s or 'Error' in s or 'out of memory' in s
                          or 'Memory Map' in s or 'warning:' in s):
            log(f'  [GPU Qari] {s}')


def _follow(out: Path, names, cached, lock, on_read, finished) -> int:
    """Takes the worker's readings from [out] into [cached] as they come,
    until [finished]() is true and all it wrote is in. Returns how many."""
    seen = 0
    while True:
        end = finished()
        if out.exists():
            # Not splitlines(): a reading can hold U+2028 and the like, and
            # half a line would stop every passage after it being taken.
            lines = out.read_text('utf-8').split('\n')
            fresh = 0
            for raw in lines[seen:]:
                if not raw:
                    continue
                try:
                    o = json.loads(raw)
                except ValueError:
                    break  # line still being written
                with lock:
                    cached[names[o['name']]] = o['text']
                fresh += 1
            if fresh:
                seen += fresh
                on_read(seen)
        if end:
            return seen
        threading.Event().wait(0.5)


def polished(words: list[tuple[str, tuple]], reading: str, lexicon=frozenset()) -> list[tuple[str, tuple]] | None:
    """[words] (from the OCR engines) with what Qari's [reading] of the same
    passage does better, or None when it adds nothing. A vision model reads
    diacritics best, but can skip a line, invent one, repeat itself and
    misread what the engines had right, numbers above all. So it never
    replaces a passage, only words: its diacritics where it read the same
    letters; its letters only where the book knows its word and not the
    engines'. Numbers, the words of the passage and their boxes stay."""
    new = reading.split()
    if not new or not words:
        return None
    old = [letters(w) for w, _ in words]
    read = [letters(w) for w in new]
    old_letters, new_letters = ''.join(old), ''.join(read)
    if not old_letters or not new_letters or not 0.8 <= len(new_letters) / len(old_letters) <= 1.25:
        return None
    if difflib.SequenceMatcher(None, old_letters, new_letters, autojunk=False).ratio() < 0.75:
        return None
    out = list(words)
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, old, read, autojunk=False).get_opcodes():
        if tag not in ('equal', 'replace') or i2 - i1 != j2 - j1:
            continue
        for i, j in zip(range(i1, i2), range(j1, j2)):
            text, box = words[i]
            if not old[i] or not read[j] or any(c.isdigit() for c in text + new[j]):
                continue
            if old[i] != read[j] and (read[j] not in lexicon or old[i] in lexicon):
                continue
            head, _, tail = _core(text)
            out[i] = (head + _core(new[j])[1] + tail, box)
    return out if out != list(words) else None


# ---- reading a page image ----

def _tesseract_page(exe: str, png: str | bytes, tessdata: str, dpi: int, scale: float,
                    y_offset: float = 0.0) -> list[OcrWord]:
    """[scale]: points per image pixel. Accepts either in-RAM PNG bytes
    (fed via stdin without touching disk) or a file path on the C: SSD."""
    env = dict(os.environ, OMP_THREAD_LIMIT='1')  # many pages at once, one thread each
    if isinstance(png, (bytes, bytearray)):
        r = subprocess.run([exe, 'stdin', 'stdout', '--tessdata-dir', tessdata, '-l', 'ara', '--oem', '1',
                            '--psm', '3', '--dpi', str(dpi), '-c', 'tessedit_create_tsv=1'],
                           input=png, capture_output=True, env=env, creationflags=_SUBPROC_FLAGS)
    else:
        r = subprocess.run([exe, png, 'stdout', '--tessdata-dir', tessdata, '-l', 'ara', '--oem', '1',
                            '--psm', '3', '--dpi', str(dpi), '-c', 'tessedit_create_tsv=1'],
                           capture_output=True, env=env, creationflags=_SUBPROC_FLAGS)
    rows = csv.DictReader(io.StringIO(r.stdout.decode('utf-8', 'replace')),
                          delimiter='\t', quoting=csv.QUOTE_NONE)
    out: list[OcrWord] = []
    ids: dict[tuple, int] = {}
    for w in rows:
        if w.get('level') != '5' or not (w.get('text') or '').strip():
            continue
        key = (w['block_num'], w['par_num'], w['line_num'])
        line = ids.setdefault(key, len(ids))
        x, y, ww, hh = (float(w[k]) for k in ('left', 'top', 'width', 'height'))
        text = w['text'].translate(BIDI_MARKS).strip()
        if text:
            out.append(OcrWord(
                text,
                (x * scale, y * scale + y_offset, (x + ww) * scale, (y + hh) * scale + y_offset),
                float(w['conf']),
                line,
            ))
    return out


# Windows' OCR runs one page per process and leaves most cores idle with only
# 3 of them (the whole book's fast pass sat at ~20% CPU on a 20-thread Xeon);
# one per core keeps them busy. Apple Vision stays at 3.
_VISION_DEFAULT = min(os.cpu_count() or 3, 20) if os.name == 'nt' else 3
_VISION_SLOTS = threading.BoundedSemaphore(
    int(os.environ.get('NOTS_VISION_PROCS', str(max(3, _VISION_DEFAULT)))))


_WINRT: bool | None = None


def winrt_ocr_available() -> bool:
    """Whether Windows' OCR can be called from Python (pip install
    winrt-Windows.Media.Ocr and its companions, requirements.txt)."""
    global _WINRT
    if _WINRT is None:
        try:
            import winrt.windows.graphics.imaging  # noqa: F401
            import winrt.windows.media.ocr  # noqa: F401
            import winrt.windows.storage.streams  # noqa: F401
            _WINRT = sys.platform == 'win32' and os.environ.get('NOTS_WINRT', '1') == '1'
        except Exception:
            _WINRT = False
    return _WINRT


def _render_gray(pdf_path: str, pages: list[int]) -> list[tuple[int, int, int, bytes, float]]:
    """[pages] drawn in gray, in a process of its own: (page, width, height,
    pixels, points per pixel)."""
    doc = pymupdf.open(pdf_path)
    out = []
    for n in pages:
        page = doc[n - 1]
        dpi = page_dpi(page)
        pix = page.get_pixmap(dpi=dpi, colorspace=pymupdf.csGRAY, alpha=False)
        out.append((n, pix.width, pix.height, pix.samples, 72.0 / dpi))
    doc.close()
    return out


def _gray_bitmap(samples: bytes, width: int, height: int):
    from winrt.windows.graphics.imaging import BitmapPixelFormat, SoftwareBitmap
    from winrt.windows.storage.streams import DataWriter
    w = DataWriter()
    w.write_bytes(samples)
    return SoftwareBitmap.create_copy_from_buffer(w.detach_buffer(), BitmapPixelFormat.GRAY8, width, height)


def _winrt_words(result, scale: float) -> list[OcrWord]:
    """The words of an OcrResult as winocr.ps1 gives them: per line, in
    reading order by position (Windows lists Arabic words left to right)."""
    words: list[OcrWord] = []
    for li, line in enumerate(result.lines):
        found = []
        for w in line.words:
            r = w.bounding_rect
            found.append((w.text, (r.x * scale, r.y * scale, (r.x + r.width) * scale, (r.y + r.height) * scale)))
        for text, box in sorted(found, key=lambda t: -t[1][2]):
            words.append(OcrWord(text, box, -1.0, li))
    return words


def _render_pages(pdf_path: str, pages: list[int], folder: str) -> dict[int, tuple[str, float]]:
    """Draws [pages] as the OCR reads them, in a process of its own (see
    Reader._read_vision_only): page -> (PNG file, points per pixel)."""
    doc = pymupdf.open(pdf_path)
    out = {}
    for n in pages:
        page = doc[n - 1]
        dpi = page_dpi(page)
        png = str(Path(folder) / f'{n:05d}.png')
        page.get_pixmap(dpi=dpi, colorspace=pymupdf.csGRAY).save(png)
        out[n] = (png, 72.0 / dpi)
    doc.close()
    return out


def _windows_pages(pngs: dict[int, str], lang: str, scales: dict[int, float], on_page) -> None:
    """Reads [pngs] (page -> file) with the machine's own OCR (Windows' OCR, or
    Apple's Vision on a Mac; the reading is kept under 'windows' either way),
    calling [on_page] as each is done. One process does them all."""
    with tempfile.TemporaryDirectory(prefix='nots_win_', dir=str(ssd_buffer_dir())) as d:
        lst = Path(d) / 'list.txt'
        lst.write_text('\n'.join(pngs[k] for k in sorted(pngs)), 'utf-8')
        out = Path(d) / 'out.jsonl'
        names = {Path(v).stem: k for k, v in pngs.items()}
        if sys.platform == 'darwin':
            cmd = [sys.executable, str(HERE / 'visionocr.py'), '--list', str(lst), '--out', str(out), '--lang', lang]
        else:
            cmd = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                   str(HERE / 'winocr.ps1'), '-List', str(lst), '-Out', str(out), '-Lang', lang]
        with _VISION_SLOTS:
            p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 creationflags=_SUBPROC_FLAGS)
            p.wait()
        if not out.exists():
            return
        for raw in out.read_text('utf-8').splitlines():
            o = json.loads(raw)
            n = names[o['name']]
            scale = scales[n]
            words: list[OcrWord] = []
            for li, line in enumerate(o.get('lines') or []):
                # Windows lists a line's words left to right: reading order
                # for Arabic is by position.
                for w in sorted(line, key=lambda w: -w[3]):
                    words.append(OcrWord(w[0], tuple(v * scale for v in w[1:5]), -1.0, li))
            on_page(n, words)


class Reader:
    """Reads pages with every engine available, keeping what each read in a
    cache file: an interrupted run, or a second run with a corrected text,
    does not read a page twice."""

    def __init__(self, pdf_path: str, tessdata: str | None, cache_path: str | None,
                 fingerprint: str = '', workers: int | None = None, log=print):
        self.pdf_path = pdf_path
        self.tessdata = tessdata
        self.cache_path = cache_path
        self.fingerprint = fingerprint
        self.workers = workers or default_workers()
        self.log = log
        self.apple_lang = apple_ocr_language()
        self.win_lang = windows_ocr_language() or self.apple_lang
        # On a Mac, Vision reads alone unless Tesseract is asked for.
        self.tess = (find_tesseract() if tessdata and not (self.apple_lang and not os.environ.get('NOTS_MAC_TESSERACT'))
                     else None)
        self.gpu = nvidia_gpu_info()
        self.cache: dict[str, dict] = {
            'tesseract': {}, 'windows': {}, 'mupdf': {}, 'qari': {}, 'strips': {}
        }
        self.lock = threading.Lock()
        self._load()

    @property
    def usable(self) -> bool:
        return bool(self.tess or self.win_lang or self.tessdata)

    def describe(self) -> str:
        names = []
        if self.tess:
            names.append(f'Tesseract ({self.workers} CPU workers)')
        if self.apple_lang:
            names.append(f'Apple Vision ({self.apple_lang}, accurate)')
        elif self.win_lang:
            names.append(f'Windows OCR ({self.win_lang})')
        base = ' + '.join(names) or 'MuPDF built-in Tesseract'
        ram = system_ram_info()
        if self.gpu:
            base += (f' | GPU: {self.gpu["name"]} ({self.gpu["vram_mb"]} MiB VRAM)'
                     f' + RAM ({ram["total_mb"]} MiB) + C: SSD')
        return base

    def _load(self):
        if not self.cache_path or not os.path.exists(self.cache_path):
            return
        try:
            with open(self.cache_path, encoding='utf-8') as f:
                raw = json.load(f)
            for eng in ('tesseract', 'windows', 'mupdf'):
                self.cache[eng] = {int(k): v for k, v in raw.get(eng, {}).items()}
            self.cache['qari'] = raw.get('qari', {})
            self.cache['strips'] = raw.get('strips', {})
        except Exception as e:
            # Hours of reading may be in there: keep it, whatever is wrong with
            # it, and do not let the next save write an empty cache in its place.
            kept = f'{self.cache_path}.unread-{int(time.time())}'
            os.replace(self.cache_path, kept)
            self.cache = {e: {} for e in self.cache}
            self.log(f'  WARNING: the OCR cache could not be read ({e!r}); it was kept as {kept}')

    def save(self):
        if not self.cache_path:
            return
        tmp = self.cache_path + '.part'
        with self.lock:
            data = {'pdf': self.fingerprint, **{e: {str(k): v for k, v in c.items()}
                                                for e, c in self.cache.items()}}
            # dumps, not dump: dump writes through the pure-Python encoder in
            # millions of small pieces (10 s for a 7 MB cache, every minute,
            # holding up every thread); dumps uses the C encoder.
            text = json.dumps(data, ensure_ascii=False)
            with open(tmp, 'w', encoding='utf-8') as f:
                f.write(text)
            # On Windows the target may be briefly held by an antivirus scan or
            # another reader: retry instead of losing the whole run.
            for attempt in range(20):
                try:
                    os.replace(tmp, self.cache_path)
                    return
                except PermissionError:
                    threading.Event().wait(0.25 * (attempt + 1))
            self.log('  WARNING: OCR cache file is locked by another program; will save it later')

    def read(self, numbers: list[int], fast: bool = False) -> dict[int, dict[str, list[OcrWord]]]:
        """page -> engine -> words, for the 1-based [numbers].
        When [fast] is True and Windows OCR is available, only Windows OCR is
        run for uncached pages (used for rapid page offset matching and
        source-covered skeleton alignment)."""
        use_tess = bool(self.tess) and not (fast and self.win_lang)
        need_t = [n for n in numbers if use_tess and n not in self.cache['tesseract']]
        need_w = [n for n in numbers if self.win_lang and n not in self.cache['windows']]
        need_m = [n for n in numbers if not self.tess and not self.win_lang and n not in self.cache['mupdf']
                  and n not in self.cache['tesseract'] and n not in self.cache['windows']]
        needed_any = set(need_t) | set(need_w) | set(need_m)
        if len(numbers) > len(needed_any) and len(numbers) > len( needed_any ) and (len(numbers) - len(needed_any)) > 0:
            self.log(f'  OCR: {len(numbers) - len(needed_any)} pages already read (cache)')
        if need_w and not need_t and winrt_ocr_available() and not self.apple_lang:
            self._read_winrt(need_w)
            need_w = [n for n in need_w if n not in self.cache['windows']]
        if need_w and not need_t and len(need_w) >= 24:
            self._read_vision_only(need_w)
            need_w = [n for n in need_w if n not in self.cache['windows']]
        if need_t and not need_w and len(need_t) >= 8:
            self._read_tess_parallel(need_t)
            need_t = [n for n in need_t if n not in self.cache['tesseract']]
        if need_t or need_w:
            self._read_images(sorted(set(need_t) | set(need_w)), set(need_t), set(need_w))
        if need_m:
            self._read_mupdf(need_m)
        return {n: {e: [OcrWord.unpack(v) for v in self.cache[e][n]]
                    for e in ('tesseract', 'windows', 'mupdf') if n in self.cache[e]} for n in numbers}

    def read_strips(self, strips: dict[int, tuple[float, float]]) -> dict[int, list[OcrWord]]:
        """Reads horizontal strips (1-based book page -> (y0, y1) in points)
        with Tesseract in parallel across CPU workers. Keeps rendered strips
        in System RAM when available, overflowing onto the C: SSD when RAM
        usage rises above 82%."""
        if not self.tess or not strips:
            return {}
        out: dict[int, list[OcrWord]] = {}
        todo: list[tuple[int, str, float, float]] = []
        for n, (y0, y1) in sorted(strips.items()):
            if n in self.cache['tesseract']:
                # Filter full-page cached Tesseract words to the strip
                out[n] = [OcrWord.unpack(v) for v in self.cache['tesseract'][n]
                          if y0 - 12 <= 0.5 * (v[2] + v[4]) <= y1 + 12]
                continue
            key = f'{n}:{round(y0)}:{round(y1)}'
            if key in self.cache['strips']:
                out[n] = [OcrWord.unpack(v) for v in self.cache['strips'][key]]
            else:
                todo.append((n, key, y0, y1))

        if not todo:
            return out

        doc = pymupdf.open(self.pdf_path)
        total = len(todo)
        done = [0]
        slots = threading.BoundedSemaphore(self.workers * 4)

        def strip_job(n: int, key: str, payload: str | bytes, dpi: int, scale: float, y_off: float):
            try:
                if isinstance(payload, str):
                    # Stream from C: SSD overflow buffer back into System RAM
                    data = Path(payload).read_bytes()
                    Path(payload).unlink(missing_ok=True)
                else:
                    data = payload
                words = _tesseract_page(self.tess, data, self.tessdata, dpi, scale, y_offset=y_off)
                with self.lock:
                    self.cache['strips'][key] = [w.pack() for w in words]
                    out[n] = words
                    done[0] += 1
                    k = done[0]
                if k % 25 == 0 or k == total:
                    self.save()
                    self.log(f'  OCR (gap strips): {k}/{total} regions read')
            finally:
                if isinstance(payload, str):
                    Path(payload).unlink(missing_ok=True)
                slots.release()

        with tempfile.TemporaryDirectory(prefix='nots_strip_', dir=str(ssd_buffer_dir())) as tmp:
            with ThreadPoolExecutor(self.workers) as pool:
                for idx, (n, key, y0, y1) in enumerate(todo):
                    page = doc[n - 1]
                    dpi = page_dpi(page)
                    clip = pymupdf.Rect(0, max(0.0, y0 - 8.0), page.rect.width, min(page.rect.height, y1 + 8.0))
                    slots.acquire()
                    pix = page.get_pixmap(dpi=dpi, clip=clip, colorspace=pymupdf.csGRAY, alpha=False)
                    ram = system_ram_info() if idx % 8 == 0 else {'avail_mb': 4096, 'used_pct': 50}
                    if ram['avail_mb'] > 1800 and ram['used_pct'] < 82:
                        # Keep directly in System RAM, as raw gray (PGM): PNG's
                        # compression in this one thread held up Tesseract.
                        payload: str | bytes = b'P5\n%d %d\n255\n' % (pix.width, pix.height) + pix.samples
                    else:
                        # RAM full -> spill to C: SSD buffer
                        png_path = str(Path(tmp) / f'{n:05d}_{round(clip.y0)}.png')
                        pix.save(png_path)
                        payload = png_path
                    pool.submit(strip_job, n, key, payload, dpi, 72.0 / dpi, clip.y0)
        doc.close()
        self.save()
        return out

    def _read_winrt(self, pages: list[int]):
        """Windows' OCR called from this process (the winrt packages), on
        the pages' pixels as drawn: no PNG files, no PowerShell started for
        each batch. One engine reads one page at a time, so there is one per
        core, all at once. 96 pages of al-Ghadir: 6.3 s, against twice that
        through PowerShell, with the same letters right (0.84)."""
        import asyncio
        from winrt.windows.globalization import Language
        from winrt.windows.media.ocr import OcrEngine
        total = len(pages)
        done = [0]
        slots = _VISION_SLOTS._initial_value
        size = max(2, min(12, -(-total // (3 * slots))))
        chunks = [pages[i:i + size] for i in range(0, total, size)]
        # Drawing a page costs 0.13 s for most scans and 0.62 s for the big ones (al-A'yan: a 3720x4895
        # image): with 4 drawing processes among 20 threads the OCR engines waited. Half the cores draw.
        renderers = max(1, min(10, (os.cpu_count() or 2) // 2, len(chunks)))

        def on_page(n: int, words: list[OcrWord]):
            with self.lock:
                self.cache['windows'][n] = [w.pack() for w in words]
                done[0] += 1
                k = done[0]
            if total >= 24 and (k % 50 == 0 or k == total):
                self.log(f'  OCR (fast Windows pass): {k}/{total} pages read')

        async def run(draw):
            loop = asyncio.get_running_loop()
            # Drawing outruns reading (some 40 pages/s against 15): a full
            # queue holds the drawing back, at about 4 MB a page.
            queue: asyncio.Queue = asyncio.Queue(maxsize=2 * slots)
            engines = [OcrEngine.try_create_from_language(Language(self.win_lang)) for _ in range(slots)]
            if not all(engines):
                raise RuntimeError(f'no Windows OCR engine for {self.win_lang}')

            async def feed():
                # A few batches drawn ahead, not the whole book: a page is
                # 4 MB of pixels.
                todo = list(chunks)
                running = set()
                while todo or running:
                    while todo and len(running) < 2 * renderers:
                        running.add(loop.run_in_executor(draw, _render_gray, self.pdf_path, todo.pop(0)))
                    finished, running = await asyncio.wait(running, return_when=asyncio.FIRST_COMPLETED)
                    for f in finished:
                        for item in f.result():
                            await queue.put(item)
                for _ in engines:
                    await queue.put(None)

            async def read(engine):
                while (item := await queue.get()) is not None:
                    n, w, h, samples, scale = item
                    result = await engine.recognize_async(_gray_bitmap(samples, w, h))
                    on_page(n, _winrt_words(result, scale))

            await asyncio.gather(feed(), *(read(e) for e in engines))

        try:
            with ProcessPoolExecutor(renderers) as draw:
                asyncio.run(run(draw))
        except Exception as e:  # the pages left are read the usual way
            self.log(f'  OCR: Windows OCR in-process stopped ({e!r}); going on with PowerShell')
        self.save()

    def _read_tess_parallel(self, pages: list[int]):
        """Tesseract on whole pages, drawn in processes of their own and
        handed over as raw gray pixels (PGM): drawing and compressing each
        page to PNG in this thread fed the 20 Tesseract processes too slowly,
        and the CPU sat at 30-70% through the Tesseract phase."""
        total = len(pages)
        done = [0]
        size = max(2, min(8, -(-total // (3 * self.workers))))
        chunks = [pages[i:i + size] for i in range(0, total, size)]
        # Drawing a page costs 0.13 s for most scans and 0.62 s for the big ones (al-A'yan: a 3720x4895
        # image): with 4 drawing processes among 20 threads the OCR engines waited. Half the cores draw.
        renderers = max(1, min(10, (os.cpu_count() or 2) // 2, len(chunks)))
        slots = threading.BoundedSemaphore(self.workers * 2)  # pages drawn ahead, 4 MB each

        def tess_job(n: int, w: int, h: int, samples: bytes, scale: float):
            try:
                pgm = b'P5\n%d %d\n255\n' % (w, h) + samples
                words = _tesseract_page(self.tess, pgm, self.tessdata, round(72.0 / scale), scale)
                with self.lock:
                    self.cache['tesseract'][n] = [x.pack() for x in words]
                    done[0] += 1
                    k = done[0]
                if k % 20 == 0 or k == total:
                    self.log(f'  OCR: {k}/{total} pages read')
            finally:
                slots.release()

        try:
            with ProcessPoolExecutor(renderers) as draw, ThreadPoolExecutor(self.workers) as pool:
                todo, running = list(chunks), set()
                while todo or running:
                    while todo and len(running) < 2 * renderers:
                        running.add(draw.submit(_render_gray, self.pdf_path, todo.pop(0)))
                    finished, running = wait(running, return_when=FIRST_COMPLETED)
                    for f in finished:
                        for item in f.result():
                            slots.acquire()
                            pool.submit(tess_job, *item)
        except Exception as e:  # the pages left are read the usual way
            self.log(f'  OCR: parallel Tesseract stopped ({e!r}); going on page by page')
        self.save()

    def _read_vision_only(self, pages: list[int]):
        """The fast pass (the machine's own OCR alone) on many pages. A page
        takes 0.2 s to render and save, and that holds the GIL: one thread
        could not keep up with 20 OCR processes (464 pages: 137 s). Processes
        render them, and each batch goes to the OCR as soon as it is drawn,
        in batches small enough to keep every OCR process busy. Pages it
        could not read are left for _read_images."""
        total = len(pages)
        done = [0]
        slots = _VISION_SLOTS._initial_value
        size = max(4, min(30, -(-total // (2 * slots))))
        chunks = [pages[i:i + size] for i in range(0, total, size)]

        def on_page(n: int, words: list[OcrWord]):
            with self.lock:
                self.cache['windows'][n] = [w.pack() for w in words]
                done[0] += 1
                k = done[0]
            if k % 50 == 0 or k == total:
                self.log(f'  OCR (fast Windows pass): {k}/{total} pages read')

        def ocr(drawn: dict[int, tuple[str, float]]):
            try:
                _windows_pages({n: v[0] for n, v in drawn.items()}, self.win_lang,
                               {n: v[1] for n, v in drawn.items()}, on_page)
            finally:
                for png, _ in drawn.values():
                    Path(png).unlink(missing_ok=True)

        renderers = max(1, min(8, (os.cpu_count() or 2) // 2, len(chunks)))
        try:
            with tempfile.TemporaryDirectory(prefix='nots_ocr_', dir=str(ssd_buffer_dir())) as tmp, \
                    ProcessPoolExecutor(renderers) as draw, ThreadPoolExecutor(slots) as read:
                drawing = [draw.submit(_render_pages, self.pdf_path, c, tmp) for c in chunks]
                reading = [read.submit(ocr, f.result()) for f in as_completed(drawing)]
                for f in reading:
                    f.result()
        except Exception as e:  # the pages left are read the usual way
            self.log(f'  OCR: parallel fast pass stopped ({e!r}); going on page by page')
        self.save()

    def _read_images(self, pages: list[int], need_t: set[int], need_w: set[int]):
        doc = pymupdf.open(self.pdf_path)
        total = len(need_t) or len(pages)
        done = [0]
        slots = threading.BoundedSemaphore(self.workers * 3)  # pages buffered in RAM / C: SSD ahead of Tesseract
        pending_uses: dict[int, int] = {
            n: (1 if n in need_t else 0) + (1 if n in need_w else 0) for n in pages
        }
        png_paths: dict[int, str] = {}

        def release_png(n: int):
            with self.lock:
                pending_uses[n] = pending_uses.get(n, 1) - 1
                if pending_uses[n] <= 0 and n in png_paths:
                    Path(png_paths.pop(n)).unlink(missing_ok=True)

        def tess_job(n: int, payload: str | bytes, dpi: int, scale: float):
            try:
                if isinstance(payload, str) and n not in need_w:
                    data: str | bytes = Path(payload).read_bytes()
                else:
                    data = payload
                words = _tesseract_page(self.tess, data, self.tessdata, dpi, scale)
                with self.lock:
                    self.cache['tesseract'][n] = [w.pack() for w in words]
                    done[0] += 1
                    k = done[0]
                if k % 20 == 0 or k == total:
                    self.save()
                    self.log(f'  OCR: {k}/{total} pages read')
            finally:
                release_png(n)
                slots.release()

        def win_batch_job(chunk: dict[int, str], scales_sub: dict[int, float]):
            try:
                def win_page(n: int, words: list[OcrWord]):
                    with self.lock:
                        self.cache['windows'][n] = [w.pack() for w in words]
                        if not need_t:
                            done[0] += 1
                            k = done[0]
                            if k % 50 == 0 or k == total:
                                self.log(f'  OCR (fast Windows pass): {k}/{total} pages read')
                _windows_pages(chunk, self.win_lang, scales_sub, win_page)
            finally:
                for n in chunk:
                    release_png(n)

        with tempfile.TemporaryDirectory(prefix='nots_ocr_', dir=str(ssd_buffer_dir())) as tmp:
            win_batch: dict[int, str] = {}
            scales: dict[int, float] = {}
            win_chunk_size = max(12, min(60, -(-len(need_w) // 4))) if need_w else 32
            with ThreadPoolExecutor(self.workers + 2) as pool:
                for idx, n in enumerate(pages):
                    page = doc[n - 1]
                    dpi = page_dpi(page)
                    if n in need_t:
                        slots.acquire()
                    pix = page.get_pixmap(dpi=dpi, colorspace=pymupdf.csGRAY)
                    scales[n] = 72.0 / dpi
                    ram = system_ram_info() if idx % 6 == 0 else {'avail_mb': 4096, 'used_pct': 50}
                    if n not in need_w and ram['avail_mb'] > 1800 and ram['used_pct'] < 82:
                        # Pure RAM buffer when Windows OCR doesn't need a file path
                        pool.submit(tess_job, n, pix.tobytes('png'), dpi, scales[n])
                    else:
                        # Spill to C: SSD buffer (or share file with Windows OCR)
                        png = str(Path(tmp) / f'{n:05d}.png')
                        pix.save(png)
                        with self.lock:
                            png_paths[n] = png
                        if n in need_w:
                            win_batch[n] = png
                            if len(win_batch) >= win_chunk_size:
                                chunk = dict(win_batch)
                                scales_sub = {k: scales[k] for k in chunk}
                                win_batch.clear()
                                pool.submit(win_batch_job, chunk, scales_sub)
                        if n in need_t:
                            pool.submit(tess_job, n, png, dpi, scales[n])
                if win_batch:
                    chunk = dict(win_batch)
                    scales_sub = {k: scales[k] for k in chunk}
                    win_batch.clear()
                    pool.submit(win_batch_job, chunk, scales_sub)
        doc.close()
        self.save()

    def _read_mupdf(self, numbers: list[int]):
        doc = pymupdf.open(self.pdf_path)
        for k, n in enumerate(numbers, 1):
            page = doc[n - 1]
            tp = page.get_textpage_ocr(language='ara', dpi=page_dpi(page), full=True, tessdata=self.tessdata)
            lines: dict[tuple, list] = {}
            for x0, y0, x1, y1, w, block, line, _ in page.get_text('words', textpage=tp):
                lines.setdefault((block, line), []).append((w, (x0, y0, x1, y1)))
            words: list[OcrWord] = []
            for li, ws in enumerate(sorted(lines.values(), key=lambda ws: min(b[1] for _, b in ws))):
                for w, b in sorted(ws, key=lambda wb: -wb[1][2]):
                    words.append(OcrWord(w, b, -1.0, li))
            self.cache['mupdf'][n] = [w.pack() for w in words]
            if k % 20 == 0 or k == len(numbers):
                self.save()
                self.log(f'  OCR: {k}/{len(numbers)} pages read')
        doc.close()


# The most to read a page at. Both engines read a 400 dpi scan no better at
# 400 than at 300 (24 pages of al-Ghadir, letters right against its text:
# Tesseract 0.831 at 400, 0.839 at 300; Windows 0.843 and 0.847), and a
# third fewer pixels is a third less to draw, save and read.
OCR_MAX_DPI = int(os.environ.get('NOTS_OCR_DPI', '300'))


def page_dpi(page: pymupdf.Page) -> int:
    """The resolution to read a page at: its scan's own when it is a scan at
    a sensible one (resampling up only blurs it), at most OCR_MAX_DPI."""
    try:
        best = 0
        for info in page.get_image_info():
            w = info['bbox'][2] - info['bbox'][0]
            if w > page.rect.width * 0.5 and info.get('width'):
                best = max(best, round(info['width'] / (w / 72)))
        if 200 <= best <= 400:
            return min(best, OCR_MAX_DPI)
    except Exception:
        pass
    return min(300, OCR_MAX_DPI)


# ---- merging two readings ----

PUNCT_FIX = str.maketrans({'»': '،', '«': '،'})


def tidy(word: str, line_text: str = '') -> str:
    """Corrects what Tesseract systematically misreads: the Arabic comma as
    a guillemet, unless the line really has a quote opened and closed."""
    if ('»' in word or '«' in word) and not ('«' in line_text and '»' in line_text):
        return word.translate(PUNCT_FIX)
    return word


def _overlap_x(a, b) -> float:
    return min(a[2], b[2]) - max(a[0], b[0])


def _overlap_y(a, b) -> float:
    return min(a[3], b[3]) - max(a[1], b[1])


def _known(words: list[OcrWord], lexicon) -> int:
    return sum(len(letters(w.text)) for w in words if letters(w.text) in lexicon)


def _mid_y(w: OcrWord) -> float:
    return (w.box[1] + w.box[3]) / 2


def _tilt(words: list[OcrWord]) -> float:
    """How much the scan leans: what its long lines rise per point across."""
    lines: dict[int, list[OcrWord]] = collections.defaultdict(list)
    for w in words:
        lines[w.line].append(w)
    slopes = []
    for v in lines.values():
        if len(v) >= 4:
            a, b = min(v, key=lambda w: w.box[0]), max(v, key=lambda w: w.box[2])
            across = (b.box[0] + b.box[2] - a.box[0] - a.box[2]) / 2
            if across > 80:
                slopes.append((_mid_y(b) - _mid_y(a)) / across)
    return sorted(slopes)[len(slopes) // 2] if len(slopes) >= 3 else 0.0


def rows_of(words: list[OcrWord], tilt: float = 0.0) -> list[list[OcrWord]]:
    """The rows [words] stand on, top to bottom, each right to left: the
    page as the eye reads it. An engine's own lines will not do: Tesseract
    takes a column of numbers, a centred title or the halves of a verse for
    blocks of their own, and joins two rows where a tall mark touches."""
    if not words:
        return []
    heights = sorted(w.box[3] - w.box[1] for w in words)
    usual = heights[len(heights) // 2]

    def level(w):
        return _mid_y(w) - tilt * (w.box[0] + w.box[2]) / 2

    rows: list[list] = []  # [level, height, words]
    for w in sorted(words, key=level):
        y = level(w)
        h = min(w.box[3] - w.box[1], 1.3 * usual)
        for row in reversed(rows[-3:]):
            if abs(y - row[0]) <= 0.45 * max(h, row[1]):
                row[0] = (row[0] * len(row[2]) + y) / (len(row[2]) + 1)
                row[1] = max(row[1], h)
                row[2].append(w)
                break
        else:
            rows.append([y, h, [w]])
    return [sorted(r[2], key=lambda w: -w.box[2]) for r in rows]


def column_cut(words: list[OcrWord], tilt: float = 0.0) -> float | None:
    """Where a page set in two columns of text divides, or None. A column
    of numbers beside text, as in an index, is no column of text: each
    number belongs to the row it stands on."""
    rows = rows_of(words, tilt)
    if len(rows) < 6:
        return None
    left, right, step = min(w.box[0] for w in words), max(w.box[2] for w in words), 2.0
    cover = [0] * (int((right - left) / step) + 2)
    for row in rows:
        for b in {b for w in row for b in range(int((w.box[0] - left) / step), int((w.box[2] - left) / step) + 1)}:
            cover[b] += 1
    best, run, start = (0, 0), 0, 0
    for b in range(int(0.2 * len(cover)), int(0.8 * len(cover))):
        if cover[b] <= 0.08 * len(rows):
            start = b if run == 0 else start
            run += 1
            best = max(best, (run, start))
        else:
            run = 0
    if best[0] * step < 6:
        return None
    cut = left + (best[1] + best[0] / 2) * step

    def text(side):
        counts = sorted(sum(1 for w in row if len(letters(w.text)) >= 2) for row in rows_of(side, tilt))
        return len(counts) >= 5 and counts[len(counts) // 2] >= 3

    sides = [w for w in words if w.box[0] + w.box[2] >= 2 * cut], [w for w in words if w.box[0] + w.box[2] < 2 * cut]
    return cut if text(sides[0]) and text(sides[1]) else None


ARABIC_DIGITS = '٠١٢٣٤٥٦٧٨٩'
# In print these look alike: the engines read the Arabic five as a zero.
DIGITS_READ_LATIN = str.maketrans('0123456789', '٥١٢٣٤٥٦٧٨٩')
_ELLIPSIS_TAIL = re.compile(r'(\.{2,}).$')
_LEADING_COMMA = re.compile(r'^[،؛]+[\u064B-\u0652]*(?=\S)')


def _finish(words: list[OcrWord]) -> list[OcrWord]:
    """What is left of the engines' habits once a page is one reading."""
    digits = [c for w in words for c in w.text if c.isdigit()]
    arabic = sum(c in ARABIC_DIGITS for c in digits)
    for w in words:
        if arabic and arabic >= len(digits) - arabic:
            w.text = w.text.translate(DIGITS_READ_LATIN)
        w.text = _ELLIPSIS_TAIL.sub(r'\1', w.text)      # a closing bracket read as a letter
        w.text = _LEADING_COMMA.sub('', w.text)         # an opening one read as a comma
    return words


def _once(row: list[OcrWord], lexicon) -> list[OcrWord]:
    """A row where no place is read twice: of two words on the same spot,
    the one the book knows, then the longer, then the surer."""
    out: list[OcrWord] = []
    for w in row:
        other = next((o for o in out if _overlap_x(o.box, w.box)
                      > 0.6 * min(o.box[2] - o.box[0], w.box[2] - w.box[0])), None)
        if other is None:
            out.append(w)
        else:
            def rank(x):
                return letters(x.text) in lexicon, len(letters(x.text)), x.conf
            if rank(w) > rank(other):
                out[out.index(other)] = w
    return out


def merge(tess: list[OcrWord], win: list[OcrWord], lexicon=frozenset(), columns: bool = True) -> list[OcrWord]:
    """One reading of a page out of two, row by row. In each stretch where
    the two overlap: same letters, keep Tesseract's word (with its
    diacritics); different, keep the side the book's vocabulary knows
    better, then the side Tesseract is sure of. A page in true columns
    is read column by column ([columns] false reads it across)."""
    frame = win or tess
    tilt = _tilt(frame)
    cut = column_cut(frame, tilt) if columns else None
    from_tess = {id(w) for w in tess}
    every = [*tess, *win]
    if cut is None:
        parts = [every]
    else:
        parts = [[w for w in every if w.box[0] + w.box[2] >= 2 * cut],
                  [w for w in every if w.box[0] + w.box[2] < 2 * cut]]
    out: list[OcrWord] = []
    number = 0
    for part in parts:
        for row in rows_of(part, tilt):
            ts = _once([w for w in row if id(w) in from_tess], lexicon)
            ws = [w for w in row if id(w) not in from_tess]
            line_text = ' '.join(w.text for w in ts)
            for t_part, w_part in _stretches(ts, ws):
                for w in _choose(t_part, w_part, lexicon, line_text):
                    w.line = number
                    out.append(w)
            number += 1
    return _finish(out)


def _stretches(ts: list[OcrWord], ws: list[OcrWord]):
    """Groups a line's two readings, right to left, into stretches of words
    that overlap each other."""
    i = j = 0
    while i < len(ts) or j < len(ws):
        if i >= len(ts):
            yield [], [ws[j]]
            j += 1
            continue
        if j >= len(ws):
            yield [ts[i]], []
            i += 1
            continue
        a, b = ts[i], ws[j]
        if _overlap_x(a.box, b.box) <= 0:
            if a.box[0] >= b.box[2]:
                yield [a], []
                i += 1
            else:
                yield [], [b]
                j += 1
            continue
        tp, wp = [a], [b]
        i += 1
        j += 1
        left = min(a.box[0], b.box[0])
        grew = True
        while grew:
            grew = False
            if i < len(ts) and ts[i].box[2] > left + 1:
                left = min(left, ts[i].box[0])
                tp.append(ts[i])
                i += 1
                grew = True
            if j < len(ws) and ws[j].box[2] > left + 1:
                left = min(left, ws[j].box[0])
                wp.append(ws[j])
                j += 1
                grew = True
        yield tp, wp


def _choose(tp: list[OcrWord], wp: list[OcrWord], lexicon, line_text: str) -> list[OcrWord]:
    def keep_t(both=False):
        return [OcrWord(tidy(w.text, line_text), w.box, w.conf, w.line, both) for w in tp]

    if not wp:
        return keep_t()
    line = tp[0].line if tp else wp[0].line
    win_words = [OcrWord(w.text, w.box, w.conf, line) for w in wp]
    if not tp:
        return win_words
    lt = ''.join(letters(w.text) for w in tp)
    lw = ''.join(letters(w.text) for w in wp)
    # Numbers: Windows' OCR reads them better, where Tesseract sees letters too.
    numbers = any(c.isdigit() for w in wp for c in w.text)
    if not lw:
        return win_words if numbers or not lt else keep_t()
    if lt == lw and numbers:
        return [OcrWord(w.text, w.box, w.conf, line, True) for w in wp]
    if lt == lw:
        # Same letters: Tesseract's word has the diacritics, Windows' the
        # right punctuation (Tesseract reads commas as "؛" or "»").
        kept = [w for w in keep_t(True) if letters(w.text)]
        kept[-1].text = split_tail(kept[-1].text)[0] + split_tail(wp[-1].text)[1]
        return kept
    kt, kw = _known(tp, lexicon), _known(win_words, lexicon)
    if kt != kw:
        return keep_t() if kt > kw else _with_marks(win_words, tp)
    conf = sum(w.conf for w in tp) / len(tp)
    return keep_t() if conf >= 60 else _with_marks(win_words, tp)


SHAPES = str.maketrans({c: first for first, group in (('ب', 'بتثني'), ('ج', 'جحخ'), ('د', 'دذ'), ('ر', 'رز'),
                                                     ('س', 'سش'), ('ص', 'صض'), ('ط', 'طظ'), ('ع', 'عغ'),
                                                     ('ف', 'فق')) for c in group})


class Speller:
    """Mends misread words from the book's own text. What an engine gets
    wrong in Arabic is mostly the dots: a word the book does not know,
    with the very shape of one it writes often, is that word. Words two
    engines agree on are left alone."""

    def __init__(self, words):
        self.forms: dict[str, collections.Counter] = {}   # letters -> how the book writes them
        self.shapes: dict[str, collections.Counter] = {}  # shape -> letters
        for w in words:
            l = letters(w)
            if len(l) >= 2:
                self.forms.setdefault(l, collections.Counter())[_core(w)[1]] += 1
                self.shapes.setdefault(l.translate(SHAPES), collections.Counter())[l] += 1

    def _same_shape(self, l: str) -> str | None:
        best = self.shapes.get(l.translate(SHAPES), collections.Counter()).most_common(2)
        if not best or best[0][1] < 2 or (len(best) > 1 and best[0][1] < 3 * best[1][1]):
            return None
        changed = sum(a != b for a, b in zip(l, best[0][0]))
        # Three letters are too few to tell a word by, unless it is everywhere.
        if changed > (1 if len(l) < 7 else 2) or (len(l) < 4 and best[0][1] < 1000):
            return None
        return best[0][0]

    def _mended(self, l: str, first: bool) -> str | None:
        """What the book writes for [l], with the "و" the print joins to a
        word and the source may write apart."""
        if l in self.forms or (l[0] == 'و' and l[1:] in self.forms):
            return None
        good = self._same_shape(l)
        if good:
            return self.forms[good].most_common(1)[0][0]
        if l[0] == 'و' and len(l) >= 4:
            good = self._same_shape(l[1:])
            if good:
                return 'و' + self.forms[good].most_common(1)[0][0]
        if first and l[0] in 'زف' and l[1:] in self.forms:  # an opening bracket read as a letter
            return self.forms[l[1:]].most_common(1)[0][0]
        return None

    def mend(self, words: list[OcrWord]) -> list[OcrWord]:
        for k, w in enumerate(words):
            l = letters(w.text)
            if w.both or len(l) < 3 or any(c.isdigit() for c in w.text):
                continue
            better = self._mended(l, k == 0 or words[k - 1].line != w.line)
            if better:
                head, _, tail = _core(w.text)
                w.text = head + better + tail
        return words


def _core(word: str) -> tuple[str, str, str]:
    """A word's opening punctuation, the word, its closing punctuation."""
    body, tail = split_tail(word)
    k = 0
    while k < len(body) and unicodedata.category(body[k])[0] not in 'LN':
        k += 1
    return body[:k], body[k:], tail


def split_tail(word: str) -> tuple[str, str]:
    """A word and the punctuation closing it."""
    k = len(word)
    while k > 0 and unicodedata.category(word[k - 1])[0] not in 'LMN':
        k -= 1
    return word[:k], word[k:]


def _clusters(text: str) -> list[list[str]]:
    out: list[list[str]] = []
    for c in text:
        if unicodedata.category(c) in ('Mn', 'Me') and out:
            out[-1].append(c)
        else:
            out.append([c])
    return out


def _with_marks(win_words: list[OcrWord], tp: list[OcrWord]) -> list[OcrWord]:
    """Windows' OCR reads no diacritics: the letters it shares with
    Tesseract's reading of the same stretch take Tesseract's."""
    tc = [cl for w in tp for cl in _clusters(w.text) if len(cl) > 1 or letters(cl[0])]
    t_letters = ''.join(cl[0] for cl in tc).translate(FOLD)
    if not any(len(cl) > 1 for cl in tc):
        return win_words
    wc = [_clusters(w.text) for w in win_words]
    flat = [(wi, ci) for wi, cls in enumerate(wc) for ci in range(len(cls))]
    w_letters = ''.join(wc[wi][ci][0] for wi, ci in flat).translate(FOLD)
    sm = difflib.SequenceMatcher(None, t_letters, w_letters, autojunk=False)
    for blk in sm.get_matching_blocks():
        for k in range(blk.size):
            wi, ci = flat[blk.b + k]
            wc[wi][ci] = [wc[wi][ci][0], *tc[blk.a + k][1:]]
    return [OcrWord(''.join(''.join(cl) for cl in cls), w.box, w.conf, w.line)
            for w, cls in zip(win_words, wc)]
