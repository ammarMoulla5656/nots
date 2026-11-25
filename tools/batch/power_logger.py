# -*- coding: utf-8 -*-
"""Keeps the machine's estimated power draw: every 5 s it reads the CPU
package and memory power (LibreHardwareMonitor, localhost:8085) and the
card's (nvidia-smi), and adds the board's share over the supply's efficiency,
as the dashboard does. It keeps the average, the peak and the energy since it
first ran (power_log.json, so a restart goes on from there) and the energy per
finished book, and sends them to the site every 60 s (nots/monitor/_data/power.txt).

Its own process, apart from batch_server.py: it can be started or stopped
while books are being cooked. The draw is an estimate: there is no meter on
the wall. NOTS_BASE_WATTS, NOTS_PSU_EFFICIENCY, NOTS_MAINS_VOLTS change the
assumptions; the dashboard's card uses the same defaults.
"""

import ftplib
import io
import json
import msvcrt
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

BASE_WATTS = float(os.environ.get('NOTS_BASE_WATTS', 45))
EFFICIENCY = float(os.environ.get('NOTS_PSU_EFFICIENCY', 0.85))
VOLTS = float(os.environ.get('NOTS_MAINS_VOLTS', 220))
BASE = Path(r'C:\nots_batch')
STATE = BASE / 'state' / 'power_log.json'
CONFIG = Path(__file__).with_name('publish.json')
DATA = 'nots/monitor/_data'
EVERY, PUSH_EVERY = 5.0, 60.0


def num(v):
    m = re.search(r'-?\d+(\.\d+)?', str(v or ''))
    return float(m.group(0)) if m else None


def cpu_powers() -> dict:
    """{'CPU Package': W, 'CPU Memory': W, ...} from LibreHardwareMonitor."""
    try:
        with urllib.request.urlopen('http://127.0.0.1:8085/data.json', timeout=2) as r:
            tree = json.loads(r.read().decode('utf-8'))
    except Exception:
        return {}
    out = {}

    def walk(node, device, kind):
        text, children = node.get('Text', ''), node.get('Children', [])
        if kind and not children and node.get('Value') and 'nvidia' not in device.lower():
            out[text] = num(node['Value'])
        for c in children:
            if text == 'Powers':
                walk(c, device, True)
            else:
                walk(c, text if node.get('ImageURL') else device, kind)
    walk(tree, '', False)
    return out


def gpu_power() -> float:
    try:
        out = subprocess.run(['nvidia-smi', '--query-gpu=power.draw', '--format=csv,noheader,nounits'],
                             capture_output=True, text=True, timeout=5,
                             creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0)).stdout
        return num(out) or 0.0
    except Exception:
        return 0.0


def estimate() -> dict | None:
    p = cpu_powers()
    cpu = p.get('CPU Package')
    if cpu is None:
        return None
    mem, gpu = p.get('CPU Memory') or 0.0, gpu_power()
    dc = cpu + mem + gpu + BASE_WATTS
    wall = dc / EFFICIENCY
    return {'cpu': cpu, 'mem': mem, 'gpu': gpu, 'wall': wall, 'amps': wall / VOLTS}


def books_done() -> int | None:
    try:
        with urllib.request.urlopen('http://127.0.0.1:8765/api/status', timeout=5) as r:
            return json.loads(r.read().decode('utf-8')).get('done')
    except Exception:
        return None


def push(cfg: dict, payload: dict):
    ftp = ftplib.FTP_TLS(cfg['host'], timeout=60)
    ftp.login(cfg['user'], cfg['password'])
    ftp.prot_p()
    final = f'{DATA}/power.txt'
    ftp.storbinary(f'STOR {final}.part', io.BytesIO(json.dumps(payload, ensure_ascii=False).encode('utf-8')))
    try:
        ftp.delete(final)
    except Exception:
        pass
    ftp.rename(f'{final}.part', final)
    ftp.quit()


def main():
    STATE.parent.mkdir(parents=True, exist_ok=True)
    lock = open(STATE.with_name('power.lock'), 'a+b')
    try:
        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
    except OSError:
        sys.exit('already running')
    cfg = json.loads(CONFIG.read_text('utf-8')) if CONFIG.exists() else None
    st = {'since': time.time(), 'seconds': 0.0, 'wh': 0.0, 'peak': 0.0, 'peak_t': None, 'done0': None}
    if STATE.exists():
        try:
            st.update(json.loads(STATE.read_text('utf-8')))
        except Exception:
            pass
    last = time.time()
    last_push = last_save = 0.0
    now_est = None
    print(f'power logger: {BASE_WATTS} W base, {EFFICIENCY} efficiency, {VOLTS} V; since {st["since"]:.0f}', flush=True)
    while True:
        time.sleep(EVERY)
        t = time.time()
        dt = min(t - last, 3 * EVERY)   # a gap (the machine was off) is not counted
        last = t
        e = estimate()
        if e:
            now_est = e
            st['wh'] += e['wall'] * dt / 3600
            st['seconds'] += dt
            if e['wall'] > st['peak']:
                st['peak'], st['peak_t'] = e['wall'], t
        if t - last_save >= PUSH_EVERY:
            tmp = STATE.with_suffix('.part')
            tmp.write_text(json.dumps(st), 'utf-8')
            os.replace(tmp, STATE)
            last_save = t
        if cfg and now_est and t - last_push >= PUSH_EVERY:
            done = books_done()
            if st['done0'] is None and done is not None:
                st['done0'] = done
            books = (done - st['done0']) if done is not None and st['done0'] is not None else None
            avg = st['wh'] * 3600 / st['seconds'] if st['seconds'] else None
            payload = {'t': t, 'now': now_est, 'avg': avg, 'peak': st['peak'], 'peak_t': st['peak_t'],
                       'kwh': st['wh'] / 1000, 'since': st['since'], 'hours': st['seconds'] / 3600,
                       'books': books, 'wh_per_book': st['wh'] / books if books else None,
                       'assume': {'base': BASE_WATTS, 'efficiency': EFFICIENCY, 'volts': VOLTS}}
            try:
                push(cfg, payload)
                last_push = t
            except Exception as ex:
                print('push failed:', repr(ex)[:200], flush=True)
                last_push = t - PUSH_EVERY + 15   # try again in 15 s


if __name__ == '__main__':
    main()
