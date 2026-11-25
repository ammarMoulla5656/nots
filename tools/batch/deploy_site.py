# -*- coding: utf-8 -*-
"""Puts the monitoring page on the public server, in publiclibdata/nots/monitor/
and nowhere else: the FTP root also runs another live app that must not be
touched (see the guard in put()).

    python deploy_site.py --email ADDRESS        (asks for the new page password)

FTP password from NOTS_FTP_PW or asked for; the page password is stored only as
a bcrypt hash in _config.php on the server.
"""

import argparse
import ftplib
import getpass
import io
import os
from pathlib import Path

import bcrypt

HERE = Path(__file__).resolve().parent
SITE = HERE / 'site'
ROOT = 'nots/monitor'


def put(ftp: ftplib.FTP, path: str, data: bytes):
    if not (path == ROOT or path.startswith(ROOT + '/')) or '..' in path:
        raise SystemExit(f'refusing to write outside {ROOT}: {path}')
    ftp.storbinary(f'STOR {path}', io.BytesIO(data))


def mkdirs(ftp: ftplib.FTP, path: str):
    cur = ''
    for part in path.split('/'):
        cur = f'{cur}/{part}' if cur else part
        try:
            ftp.mkd(cur)
        except ftplib.error_perm:
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--host', default='ftp.alhikmeh.org')
    ap.add_argument('--user', default='devammar@alhikmeh.org')
    ap.add_argument('--email', required=True)
    a = ap.parse_args()
    ftp_pw = os.environ.get('NOTS_FTP_PW') or getpass.getpass('FTP password: ')
    page_pw = os.environ.get('NOTS_PAGE_PW') or getpass.getpass('new page password: ')
    hashed = bcrypt.hashpw(page_pw.encode(), bcrypt.gensalt(12)).decode().replace('$2b$', '$2y$', 1)
    agent_key = os.environ.get('NOTS_AGENT_KEY') or getpass.getpass("agent key (the Xeon's, from publish.json): ")
    config = ("<?php\n// Written by deploy_site.py. The password is only a bcrypt hash.\n"
              f"const NOTS_EMAIL = {repr(a.email)};\nconst NOTS_HASH = {repr(hashed)};\n"
              f"const NOTS_AGENT_KEY = {repr(agent_key)};\n").encode()

    ftp = ftplib.FTP_TLS(a.host, timeout=60)
    ftp.login(a.user, ftp_pw)
    ftp.prot_p()
    for d in (ROOT, ROOT + '/_app', ROOT + '/_data', ROOT + '/_dl'):
        mkdirs(ftp, d)
    deny = (SITE / 'deny.htaccess').read_bytes()
    files = {
        ROOT + '/_config.php': config,
        ROOT + '/.htaccess': (SITE / 'dir.htaccess').read_bytes(),
        ROOT + '/_app/.htaccess': deny,
        ROOT + '/_data/.htaccess': deny,
        ROOT + '/_dl/.htaccess': deny,
        ROOT + '/_app/dashboard.html': (HERE / 'dashboard.html').read_bytes(),
    }
    for name in ('_auth.php', 'index.php', 'data.php', 'export.php', 'logout.php', 'poll.php', 'dl.php'):
        files[f'{ROOT}/{name}'] = (SITE / name).read_bytes()
    for path, data in files.items():
        put(ftp, path, data)
        print('put', path, len(data))
    ftp.quit()


if __name__ == '__main__':
    main()
