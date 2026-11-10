import 'package:flutter_test/flutter_test.dart';
import 'package:nots/book/masdar_link.dart';
import 'package:nots/catalog/catalog_models.dart';

void main() {
  test('the link to a page of a book in Masdar', () {
    expect(
      const MasdarRef(7045, 0).pageLink(89).toString(),
      'https://alhikmeh.org/source/7045/0/89/0-1/',
    );
    // A volume of a book in volumes; never a page before the first.
    expect(
      const MasdarRef(1, 3).pageLink(0).toString(),
      'https://alhikmeh.org/source/1/3/1/0-1/',
    );
  });

  test('the volume: 0 without volumes, else its number', () {
    expect(MasdarRef.volumeOf(multiPart: false, part: 1), 0);
    expect(MasdarRef.volumeOf(multiPart: true, part: 3), 3);
  });

  test('a link is read alone or inside shared text', () {
    expect(parseMasdarLink('https://alhikmeh.org/source/7045/0/89/0-4/'), (
      id: 7045,
      volume: 0,
      page: 89,
    ));
    expect(
      parseMasdarLink(
        '«نص مختار من الكتاب»\n\nالأحكام الفقهية، صفحة 89\n'
        'https://www.alhikmeh.org/source/7045/0/89/0-1/',
      ),
      (id: 7045, volume: 0, page: 89),
    );
    expect(parseMasdarLink('https://alhikmeh.org/other/1/2/3'), isNull);
    expect(parseMasdarLink('بلا رابط'), isNull);
  });

  test('the Masdar id of a book of the catalogue, when it has one', () {
    CatalogBook book(Object? masdar) => CatalogBook.fromJson({
      'id': 'b1',
      'title': 'الأحكام الفقهية',
      'parts': const [],
      'masdar': ?masdar,
    });
    expect(book('7045').masdarId, 7045);
    expect(book(7045).masdarId, 7045);
    expect(book('').masdarId, isNull);
    expect(book('0').masdarId, isNull);
    expect(book(null).masdarId, isNull);
  });
}
