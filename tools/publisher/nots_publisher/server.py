"""The server: FTP over TLS, confined to the `nots/` folder.

The account's root also holds another application (api.php, core/, data/).
Nothing here may change it: every path that writes or deletes goes through
`_safe`, which refuses anything outside `nots/`.
"""

from __future__ import annotations

import ftplib
import io
import json
import os
import posixpath
from dataclasses import asdict, dataclass

ROOT = "nots"
CATALOG = "catalog.txt"
CATALOG_BACKUP = "catalog.bak.txt"
PUBLIC_URL = "https://alhikmeh.org/alhawzaapp/publiclibdata/nots/"


def config_path() -> str:
    base = os.environ.get("APPDATA") or os.path.expanduser("~")
    return os.path.join(base, "nots-publisher", "config.json")


@dataclass
class Account:
    """Kept in the user's profile, never in the repository or the app."""

    host: str = "ftp.alhikmeh.org"
    port: int = 21
    user: str = ""
    password: str = ""

    @staticmethod
    def load() -> "Account":
        try:
            with open(config_path(), encoding="utf-8") as f:
                return Account(**json.load(f))
        except (OSError, ValueError, TypeError):
            return Account()

    def save(self) -> None:
        path = config_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, ensure_ascii=False, indent=1)


def _safe(path: str) -> str:
    """[path] relative to `nots/` as a full server path; refuses to leave it."""
    if not path or "\\" in path or path.startswith("/"):
        raise PermissionError(f"مسار مرفوض: {path!r}")
    full = posixpath.normpath(posixpath.join(ROOT, path))
    if not full.startswith(ROOT + "/"):
        raise PermissionError(f"مسار خارج مجلد {ROOT}: {path!r}")
    return full


class Server:
    def __init__(self, account: Account):
        self.account = account
        self._ftp: ftplib.FTP_TLS | None = None

    def __enter__(self) -> "Server":
        self.connect()
        return self

    def __exit__(self, *_) -> None:
        self.close()

    def connect(self) -> None:
        self.close()
        ftp = ftplib.FTP_TLS(timeout=60, encoding="utf-8")
        ftp.connect(self.account.host, self.account.port)
        ftp.auth()
        ftp.login(self.account.user, self.account.password)
        ftp.prot_p()
        self._ftp = ftp

    def close(self) -> None:
        if self._ftp is not None:
            try:
                self._ftp.quit()
            except (OSError, EOFError, ftplib.Error):
                self._ftp.close()
            self._ftp = None

    def _mkdirs(self, folder: str) -> None:
        """Creates the folders of [folder], which is under `nots/`."""
        parts = folder.split("/")
        for i in range(2, len(parts) + 1):
            try:
                self._ftp.mkd("/".join(parts[:i]))
            except ftplib.error_perm:
                pass  # already there

    def _exists(self, full: str) -> bool:
        try:
            self._ftp.size(full)
            return True
        except ftplib.error_perm:
            return False

    def read_text(self, path: str) -> str | None:
        """Text of a file under `nots/`, or None when it does not exist."""
        full = _safe(path)
        self._ftp.voidcmd("TYPE I")
        if not self._exists(full):
            return None
        buf = io.BytesIO()
        self._ftp.retrbinary(f"RETR {full}", buf.write)
        return buf.getvalue().decode("utf-8")

    def _put(self, stream, size: int, path: str, progress=None) -> None:
        """Sends to a temporary name, checks the size, then renames: readers
        see the old file or the whole new one, never half of it."""
        full = _safe(path)
        self._mkdirs(posixpath.dirname(full))
        tmp = full + ".part"
        sent = 0

        def tick(block: bytes) -> None:
            nonlocal sent
            sent += len(block)
            if progress:
                progress(sent, size)

        self._ftp.storbinary(f"STOR {tmp}", stream, blocksize=1 << 16, callback=tick)
        self._ftp.voidcmd("TYPE I")
        got = self._ftp.size(tmp)
        if got != size:
            self._ftp.delete(tmp)
            raise IOError(f"وصل {got} بايت من {size}: {path}")
        self._ftp.rename(tmp, full)

    def upload_file(self, local: str, path: str, progress=None) -> None:
        with open(local, "rb") as f:
            self._put(f, os.path.getsize(local), path, progress)

    def write_text(self, path: str, text: str) -> None:
        data = text.encode("utf-8")
        self._put(io.BytesIO(data), len(data), path)

    def delete(self, path: str) -> None:
        """Deletes a file under `nots/`; a missing file is not an error."""
        full = _safe(path)
        try:
            self._ftp.delete(full)
        except ftplib.error_perm:
            pass

    def delete_empty_folder(self, path: str) -> None:
        try:
            self._ftp.rmd(_safe(path))
        except ftplib.error_perm:
            pass  # not empty, or already gone
