"""Paper templates of the app: the papers offered when a note or a page in a
book is made, besides the built-in plain, lined and squared ones.

    python papers.py list
    python papers.py add-page "ورقة مراجعة" review.pdf
    python papers.py add-style "مسطرة صفراء" lined fff4cc d6cfbe
    python papers.py remove <id>

A page template is a PDF: its first page is used, at its own size. A style is
blank, lined or grid, with the paper's colour and the lines' (hex RGB).

On the server: nots/papers.txt (the list the app reads) and nots/papers/.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import uuid

import pymupdf

from nots_publisher import catalog as cat
from nots_publisher.publishing import make_cover
from nots_publisher.server import Account, Server

LIST = "papers.txt"
KINDS = ("blank", "lined", "grid")


def _load(server: Server) -> dict:
    text = server.read_text(LIST)
    if text is None:
        return {"version": 1, "papers": []}
    return json.loads(text)


def _save(server: Server, data: dict) -> None:
    server.write_text(LIST, json.dumps(data, ensure_ascii=False, indent=1))


def _color(s: str) -> str:
    s = s.lstrip("#").lower()
    if len(s) != 6 or any(c not in "0123456789abcdef" for c in s):
        raise SystemExit(f"لون غير صحيح: {s} (اكتبه مثل fbf8f1)")
    return "ff" + s


def add_page(server: Server, title: str, pdf: str) -> dict:
    pid = "p" + uuid.uuid4().hex[:10]
    with tempfile.TemporaryDirectory() as tmp:
        one = os.path.join(tmp, "page.pdf")
        with pymupdf.open(pdf) as src, pymupdf.open() as out:
            out.insert_pdf(src, from_page=0, to_page=0)
            out.save(one, garbage=4, deflate=True)
        digest = cat.sha256_of(one)[:12]
        remote_pdf = f"papers/{pid}-{digest}.pdf"
        server.upload_file(one, remote_pdf)
        thumb = os.path.join(tmp, "thumb.jpg")
        with open(thumb, "wb") as f:
            f.write(make_cover(one))
        remote_thumb = f"papers/{pid}-{digest}.jpg"
        server.upload_file(thumb, remote_thumb)
    return {"id": pid, "title": title, "file": remote_pdf, "thumb": remote_thumb}


def main(argv: list[str]) -> None:
    if not argv or argv[0] not in ("list", "add-page", "add-style", "remove"):
        print(__doc__)
        return
    with Server(Account.load()) as server:
        data = _load(server)
        papers = data.setdefault("papers", [])
        cmd = argv[0]
        if cmd == "list":
            for p in papers:
                kind = p.get("style") or p.get("file")
                print(f"{p['id']}\t{p['title']}\t{kind}")
            return
        if cmd == "add-page":
            title, pdf = argv[1], argv[2]
            papers.append(add_page(server, title, pdf))
        elif cmd == "add-style":
            title, kind, paper, line = argv[1], argv[2], argv[3], argv[4]
            if kind not in KINDS:
                raise SystemExit(f"النوع واحد من: {', '.join(KINDS)}")
            code = f"{kind}|{_color(paper)}|{_color(line)}"
            papers.append({"id": "s" + uuid.uuid4().hex[:10], "title": title, "style": code})
        elif cmd == "remove":
            gone = [p for p in papers if p["id"] == argv[1]]
            if not gone:
                raise SystemExit("لا يوجد قالب بهذا الرقم")
            papers.remove(gone[0])
            _save(server, data)
            # The files go after the list stopped naming them. Notes already
            # made on this page keep their own copy on each device.
            for key in ("file", "thumb"):
                if gone[0].get(key):
                    server.delete(gone[0][key])
            print("حُذف.")
            return
        _save(server, data)
        print("تم. يظهر القالب في التطبيق عند فتح «ورقة جديدة».")


if __name__ == "__main__":
    main(sys.argv[1:])
