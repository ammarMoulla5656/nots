"""Publishing steps: what happens on the server, in which order.

Files go first and the catalogue last, so the app never lists a file that
is not there yet. Old files go only after the catalogue stopped naming them.
"""

from __future__ import annotations

import io
import os
import posixpath
import tempfile
from dataclasses import dataclass, field

import pymupdf
from PIL import Image, ImageOps

try:  # phone photos (HEIC); every other format is in Pillow itself
    from pillow_heif import register_heif_opener

    register_heif_opener()
except ImportError:
    pass

from . import catalog as cat
from .server import CATALOG, CATALOG_BACKUP, Server

COVER_MAX = 600  # pixels on the long side


@dataclass
class PartDraft:
    """A part in the form: a file to send, or one already on the server."""

    number: int
    label: str
    format: str
    pages: int
    features: dict
    local: str | None = None  # a new file
    existing: dict | None = None  # its catalogue entry when unchanged


@dataclass
class BookDraft:
    fields: dict
    parts_count: int
    parts: list[PartDraft] = field(default_factory=list)
    book_id: str | None = None
    cover_local: str | None = None
    cover_existing: str = ""


def load_catalog(server: Server) -> dict:
    text = server.read_text(CATALOG)
    return cat.empty() if text is None else cat.parse(text)


def save_catalog(server: Server, catalog: dict) -> None:
    previous = server.read_text(CATALOG)
    if previous is not None:
        server.write_text(CATALOG_BACKUP, previous)
    server.write_text(CATALOG, cat.dumps(catalog))


def cover_extensions() -> list[str]:
    """Every picture format that can be chosen as a cover."""
    Image.init()
    known = {e for e, f in Image.registered_extensions().items() if f in Image.OPEN}
    return sorted(known | {".svg", ".pdf"})


def _on_white(im: Image.Image) -> Image.Image:
    """Without this, the transparent parts of a picture come out black."""
    im = im.convert("RGBA")
    page = Image.new("RGBA", im.size, "white")
    page.alpha_composite(im)
    return page.convert("RGB")


def _rendered(source: str) -> Image.Image:
    """Formats that are drawn, not stored as pixels: SVG, PDF and the like."""
    with pymupdf.open(source) as doc:
        page = doc[0]
        zoom = COVER_MAX / max(page.rect.width, page.rect.height, 1)
        pix = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), alpha=False)
        return Image.frombytes("RGB", (pix.width, pix.height), pix.samples)


def open_cover(source: str) -> Image.Image:
    """The chosen file as a plain picture, or OSError when it is not one. An
    animation gives its first frame."""
    try:
        with Image.open(source) as im:
            return _on_white(ImageOps.exif_transpose(im))
    except OSError:
        pass
    try:
        return _rendered(source)
    except Exception as e:
        raise OSError(f"لا يمكن قراءة هذه الصورة: {os.path.basename(source)}") from e


def make_cover(source: str) -> bytes:
    """A JPEG small enough for lists, whatever was chosen: the app only ever
    receives this one format, so every device can show it."""
    im = open_cover(source)
    im.thumbnail((COVER_MAX, COVER_MAX))
    out = io.BytesIO()
    im.save(out, "JPEG", quality=82, optimize=True)
    return out.getvalue()


def _upload_cover(server: Server, book_id: str, source: str, say) -> str:
    data = make_cover(source)
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "cover.jpg")
        with open(path, "wb") as f:
            f.write(data)
        remote = cat.cover_path(book_id, cat.sha256_of(path))
        say("رفع الصورة", 0, 0)
        server.upload_file(path, remote)
    return remote


def _upload_part(server: Server, book_id: str, part: PartDraft, say) -> dict:
    digest = cat.sha256_of(part.local)
    remote = cat.part_path(book_id, part.number, part.format, digest)
    size = os.path.getsize(part.local)
    server.upload_file(
        part.local, remote,
        lambda sent, total: say(f"رفع {part.label or 'الكتاب'}", sent, total),
    )
    return {"file": remote, "size": size, "sha256": digest}


def publish(server: Server, draft: BookDraft, say=lambda *_: None) -> dict:
    """Sends a new or edited book; returns its catalogue entry."""
    book_id = draft.book_id or cat.new_book_id()
    cover = draft.cover_existing
    if draft.cover_local:
        cover = _upload_cover(server, book_id, draft.cover_local, say)
    parts = []
    for p in draft.parts:
        where = (
            _upload_part(server, book_id, p, say) if p.local
            else {k: p.existing[k] for k in ("file", "size", "sha256")}
        )
        parts.append({
            "n": p.number, "label": p.label, "format": p.format,
            "pages": p.pages, "features": p.features, **where,
        })
    book = {
        "id": book_id,
        **{k: draft.fields.get(k, "").strip() for k in cat.TEXT_FIELDS},
        "parts_count": max(draft.parts_count, len(parts)),
        "cover": cover,
        "parts": parts,
    }
    say("تحديث الفهرس", 0, 0)
    # Read again right before writing: someone else may have published.
    catalog = load_catalog(server)
    stale = cat.put(catalog, book)
    save_catalog(server, catalog)
    for path in stale:
        server.delete(path)
    return book


def unpublish(server: Server, book_id: str, say=lambda *_: None) -> None:
    say("تحديث الفهرس", 0, 0)
    catalog = load_catalog(server)
    files = cat.remove(catalog, book_id)
    save_catalog(server, catalog)
    for path in files:
        say("حذف الملفات", 0, 0)
        server.delete(path)
    server.delete_empty_folder(posixpath.join("books", book_id))
