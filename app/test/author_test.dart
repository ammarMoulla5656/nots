import 'package:flutter_test/flutter_test.dart';
import 'package:nots/catalog/author_screen.dart';

void main() {
  test('the same author is found however the name is written', () {
    expect(AuthorScreen.sameAuthor('السيد علي السيستاني', 'السيد علي السيستاني'), isTrue);
    expect(AuthorScreen.sameAuthor('الشيخ المفيد', 'الشَّيخ المُفيد'), isTrue);
    expect(AuthorScreen.sameAuthor('أبو جعفر الطوسي', 'ابو جعفر الطوسي'), isTrue);
    expect(AuthorScreen.sameAuthor('الشيخ المفيد', 'الشيخ الطوسي'), isFalse);
    expect(AuthorScreen.sameAuthor('', ''), isFalse);
  });
}
