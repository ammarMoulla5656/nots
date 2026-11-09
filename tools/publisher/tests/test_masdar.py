import unittest

from nots_publisher import masdar


class MasdarTest(unittest.TestCase):
    def test_the_list_is_read(self):
        books = masdar.load()
        self.assertGreater(len(books), 200)
        kafi = masdar.by_id(1)
        self.assertEqual(kafi.title, "الكافي")
        self.assertEqual(kafi.parts, 8)

    def test_a_book_is_found_by_its_title(self):
        self.assertEqual(masdar.best("الأحكام الفقهية").id, 7045)
        # Without hamza or diacritics, and with them.
        self.assertEqual(masdar.best("الاحكام الفقهيه").id, 7045)
        self.assertEqual(masdar.best("الأَحكامُ الفقهيّة").id, 7045)

    def test_nothing_is_filled_in_when_unsure(self):
        self.assertIsNone(masdar.best("كتاب لا يوجد في المصدر أبداً"))
        self.assertEqual(masdar.find("كتاب لا يوجد في المصدر أبداً"), [])

    def test_the_author_tells_apart_books_of_one_title(self):
        # منهاج الصالحين has eight authors in Masdar.
        self.assertIsNone(masdar.best("منهاج الصالحين"))
        self.assertEqual(masdar.best("منهاج الصالحين", "السيد علي السيستاني").id, 435)
        self.assertEqual(
            masdar.best("منهاج الصالحين", "السيد محمد سعيد الحكيم").id, 7041)

    def test_the_volumes_tell_apart_editions_of_one_author(self):
        # Two editions of المكاسب by the same author: 6 and 18 volumes.
        author = "الشيخ مرتضى الأنصاري"
        self.assertIsNone(masdar.best("المكاسب", author))
        self.assertEqual(masdar.best("المكاسب", author, parts=6).id, 490)
        self.assertEqual(masdar.best("المكاسب", author, parts=18).id, 771)

    def test_categories_are_named_as_in_the_masdar_app(self):
        self.assertEqual(masdar.category("الفقه الإسلامي والأحكام"), "الفقه")
        self.assertEqual(masdar.category("أصول الفقه والقواعد الأصولية"), "أصول الفقه")
        # Every category of the list has its short name.
        for b in masdar.load():
            self.assertLessEqual(len(masdar.category(b.subject).split()), 2, b.subject)

    def test_normalize(self):
        self.assertEqual(masdar.normalize("الشيخ المفيد (قدس سره)"), "الشيخ المفيد")
        self.assertEqual(masdar.normalize("أُصولُ الفقه"), "اصول الفقه")


if __name__ == "__main__":
    unittest.main()
