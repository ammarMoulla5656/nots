import io
import json
import os
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pymupdf
from PIL import Image

from nots_publisher import catalog as cat
from nots_publisher import publishing
from nots_publisher.inspect_book import inspect
from nots_publisher.publishing import BookDraft, PartDraft
from nots_publisher.server import CATALOG, CATALOG_BACKUP, _safe


class FakeServer:
    """Files in a dict, with the real path guard."""

    def __init__(self):
        self.files = {}

    def read_text(self, path):
        return self.files.get(_safe(path))

    def write_text(self, path, text):
        self.files[_safe(path)] = text

    def upload_file(self, local, path, progress=None):
        with open(local, "rb") as f:
            self.files[_safe(path)] = f.read()

    def delete(self, path):
        self.files.pop(_safe(path), None)

    def delete_empty_folder(self, path):
        _safe(path)


def make_pdf(path, text=None, toc=False, pages=3):
    doc = pymupdf.open()
    for _ in range(pages):
        page = doc.new_page()
        if text:
            page.insert_text((72, 72), text)
    if toc:
        doc.set_toc([[1, "one", 1]])
    doc.save(path)
    doc.close()


class PathGuard(unittest.TestCase):
    def test_stays_in_the_folder(self):
        self.assertEqual(_safe("books/x/p.pdf"), "nots/books/x/p.pdf")

    def test_refuses_the_old_application(self):
        for bad in ("../api.php", "../core/db.php", "../data/library.sqlite",
                    "books/../../index.htm", "/api.php", "..", ".", "",
                    "..\\api.php"):
            with self.assertRaises(PermissionError, msg=bad):
                _safe(bad)


class Inspecting(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def path(self, name):
        return os.path.join(self.tmp.name, name)

    def test_scanned_pdf_has_nothing_but_the_pen(self):
        p = self.path("a.pdf")
        make_pdf(p)
        f = inspect(p)["features"]
        self.assertFalse(f["search"] or f["marks"] or f["copy"] or f["toc"] or f["exact"])

    def test_pdf_with_text_and_outline(self):
        p = self.path("a.pdf")
        make_pdf(p, text="plenty of letters on this page to count", toc=True)
        info = inspect(p)
        self.assertEqual(info["pages"], 3)
        self.assertTrue(info["features"]["search"])
        self.assertTrue(info["features"]["toc"])
        self.assertFalse(info["features"]["exact"])

    def test_word_map_means_exact_text(self):
        p = self.path("a.pdf")
        make_pdf(p)
        with open(p, "ab") as f:
            f.write(b"\n9 0 obj <</NotsWords true>> stream\nendstream endobj\n")
        f = inspect(p)["features"]
        self.assertTrue(f["exact"] and f["search"] and f["toc"])

    def test_nots_package(self):
        pdf = self.path("b.pdf")
        make_pdf(pdf)
        p = self.path("a.nots")
        with zipfile.ZipFile(p, "w") as z:
            z.writestr("manifest.json", json.dumps({"format": "nots-package"}))
            z.write(pdf, "book.pdf")
            z.writestr("ink.nots", b"x")
            z.writestr("link.json", "{}")
        info = inspect(p)
        self.assertEqual(info["format"], "nots")
        self.assertTrue(info["features"]["search"])

    def test_not_a_package(self):
        p = self.path("a.nots")
        with zipfile.ZipFile(p, "w") as z:
            z.writestr("x", "y")
        with self.assertRaises(ValueError):
            inspect(p)


class Covers(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def _path(self, name):
        return os.path.join(self.dir.name, name)

    def _is_jpeg_of(self, path, colour):
        data = publishing.make_cover(path)
        self.assertEqual(data[:2], bytes([0xFF, 0xD8]))
        with Image.open(io.BytesIO(data)) as im:
            got = im.convert("RGB").getpixel((im.width // 2, im.height // 2))
        for a, b in zip(got, colour):
            self.assertLess(abs(a - b), 24, got)

    def test_every_common_format_becomes_a_jpeg(self):
        red = Image.new("RGB", (60, 90), (200, 20, 20))
        for ext in ("jpg", "png", "webp", "bmp", "gif", "tiff", "avif", "heic", "ico", "tga"):
            with self.subTest(ext):
                path = self._path(f"c.{ext}")
                red.save(path)
                self._is_jpeg_of(path, (200, 20, 20))

    def test_the_format_is_read_from_the_file_not_its_name(self):
        path = self._path("really_a_webp.jpg")
        Image.new("RGB", (60, 90), (20, 20, 200)).save(path, "WEBP")
        self._is_jpeg_of(path, (20, 20, 200))

    def test_transparent_parts_are_white_not_black(self):
        path = self._path("c.png")
        Image.new("RGBA", (60, 90), (0, 0, 0, 0)).save(path)
        self._is_jpeg_of(path, (255, 255, 255))

    def test_drawn_formats(self):
        path = self._path("c.svg")
        with open(path, "w", encoding="utf-8") as f:
            f.write('<svg xmlns="http://www.w3.org/2000/svg" width="40" height="60">'
                    '<rect width="40" height="60" fill="#0a0"/></svg>')
        self._is_jpeg_of(path, (0, 170, 0))
        doc = pymupdf.open()
        page = doc.new_page(width=100, height=140)
        page.draw_rect(page.rect, fill=(0, 0, 1))
        doc.save(self._path("c.pdf"))
        self._is_jpeg_of(self._path("c.pdf"), (0, 0, 255))

    def test_a_file_that_is_no_picture_says_so(self):
        path = self._path("c.png")
        with open(path, "wb") as f:
            f.write(b"not a picture")
        with self.assertRaises(OSError):
            publishing.make_cover(path)

    def test_the_file_dialog_offers_them(self):
        names = publishing.cover_extensions()
        for ext in (".jpg", ".png", ".webp", ".heic", ".avif", ".svg", ".tiff"):
            self.assertIn(ext, names)


class Publishing(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.server = FakeServer()

    def pdf(self, name, text):
        p = os.path.join(self.tmp.name, name)
        make_pdf(p, text=text)
        return p

    def part(self, n, local):
        return PartDraft(n, f"الجزء {n}", "pdf", 3, {}, local=local)

    def catalog(self):
        return cat.parse(self.server.files["nots/catalog.txt"])

    def draft(self, **kw):
        return BookDraft(fields={"title": "الكافي", "author": "الكليني"},
                         parts_count=2, **kw)

    def test_a_book_of_two_parts(self):
        cover = os.path.join(self.tmp.name, "c.png")
        Image.new("RGB", (1200, 1600), "red").save(cover)
        book = publishing.publish(self.server, self.draft(
            parts=[self.part(1, self.pdf("1.pdf", "one")),
                   self.part(2, self.pdf("2.pdf", "two"))],
            cover_local=cover))
        entry = self.catalog()["books"][0]
        self.assertEqual(entry["title"], "الكافي")
        self.assertEqual([p["n"] for p in entry["parts"]], [1, 2])
        for f in cat.files_of(book):
            self.assertIn("nots/" + f, self.server.files)
        data = self.server.files["nots/" + book["cover"]]
        self.assertEqual(data[:2], b"\xff\xd8")

    def test_replacing_a_part_removes_only_the_old_file(self):
        first = publishing.publish(self.server, self.draft(
            parts=[self.part(1, self.pdf("1.pdf", "one")),
                   self.part(2, self.pdf("2.pdf", "two"))]))
        keep, old = first["parts"]
        second = publishing.publish(self.server, self.draft(
            book_id=first["id"],
            parts=[PartDraft(1, "الجزء 1", "pdf", 3, {}, existing=keep),
                   self.part(2, self.pdf("3.pdf", "new"))]))
        self.assertNotIn("nots/" + old["file"], self.server.files)
        self.assertIn("nots/" + keep["file"], self.server.files)
        self.assertIn("nots/" + second["parts"][1]["file"], self.server.files)
        self.assertEqual(second["id"], first["id"])
        self.assertEqual(len(self.catalog()["books"]), 1)

    def test_unpublishing_touches_only_that_book(self):
        a = publishing.publish(self.server, self.draft(parts=[self.part(1, self.pdf("1.pdf", "a"))]))
        b = publishing.publish(self.server, self.draft(parts=[self.part(1, self.pdf("2.pdf", "b"))]))
        publishing.unpublish(self.server, a["id"])
        self.assertEqual([x["id"] for x in self.catalog()["books"]], [b["id"]])
        self.assertNotIn("nots/" + a["parts"][0]["file"], self.server.files)
        self.assertIn("nots/" + b["parts"][0]["file"], self.server.files)

    def test_previous_catalogue_is_kept_as_a_backup(self):
        publishing.publish(self.server, self.draft(parts=[self.part(1, self.pdf("1.pdf", "a"))]))
        first = self.server.files["nots/" + CATALOG]
        publishing.publish(self.server, self.draft(parts=[self.part(1, self.pdf("2.pdf", "b"))]))
        self.assertEqual(self.server.files["nots/" + CATALOG_BACKUP], first)


if __name__ == "__main__":
    unittest.main()
