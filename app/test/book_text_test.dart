import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nots/book/book_text.dart';

/// A minimal .docx with the given document.xml body and heading styles.
Uint8List _docx(String body) {
  const styles =
      '<w:styles>'
      '<w:style w:type="paragraph" w:styleId="1"><w:name w:val="heading 1"/></w:style>'
      '<w:style w:type="paragraph" w:styleId="Sub"><w:name w:val="Heading 2"/></w:style>'
      '</w:styles>';
  final doc = '<w:document><w:body>$body</w:body></w:document>';
  final a = Archive()
    ..add(ArchiveFile.bytes('word/document.xml', utf8.encode(doc)))
    ..add(ArchiveFile.bytes('word/styles.xml', utf8.encode(styles)));
  return Uint8List.fromList(ZipEncoder().encode(a));
}

String _p(String text, {String? style}) =>
    '<w:p>${style == null ? '' : '<w:pPr><w:pStyle w:val="$style"/></w:pPr>'}'
    '<w:r><w:t xml:space="preserve">$text</w:t></w:r></w:p>';
const _pageBreak = '<w:p><w:r><w:br w:type="page"/></w:r></w:p>';

void main() {
  group('normalizeForSearch', () {
    test('ignores diacritics, tatweel and letter variants', () {
      String n(String s) => normalizeForSearch(s).text;
      expect(n('الصَّلاةُ'), n('الصلاه'));
      expect(n('إِسْلام'), n('اسلام'));
      expect(n('مُسْتَحَـــبّ'), n('مستحب'));
      expect(n('على'), n('علي'));
      expect(n('مسألة ٢٠'), n('مسالة 20'));
      expect(n('  a   b  '), 'a b ');
    });

    test('maps back to the original characters', () {
      const s = 'قَالَ الشَّيْخُ';
      final n = normalizeForSearch(s);
      final i = n.text.indexOf('الشيخ');
      expect(s.substring(n.origIndex[i], n.origIndex[i + 4] + 1), 'الشَّيْخ');
    });
  });

  group('parseDocx', () {
    test('pages from page breaks, headings from heading styles', () {
      final book = parseDocx(
        _docx(
          [
            _p('غلاف الكتاب'),
            _pageBreak,
            _p('أحكام الطهارة', style: '1'),
            _p('الوضوء', style: 'Sub'),
            _p('يجب الوضوء للصلاة &amp; غيرها'),
            _pageBreak,
            _p('شروط الوضوء', style: 'Heading2'),
            _p('النص الثالث'),
          ].join(),
        ),
      );

      expect(book.pageCount, 3);
      expect(book.pages[0], 'غلاف الكتاب');
      expect(book.pages[1], contains('يجب الوضوء للصلاة & غيرها'));
      expect(book.headings.map((h) => (h.title, h.level, h.page)).toList(), [
        ('أحكام الطهارة', 1, 2),
        ('الوضوء', 2, 2),
        ('شروط الوضوء', 2, 3),
      ]);
      expect(book.sectionOf(3)?.title, 'شروط الوضوء');
      expect(book.sectionOf(1), isNull);
    });

    test('search finds every match with page and snippet', () {
      final book = parseDocx(
        _docx(
          [
            _p('الصَّلاة واجبة'),
            _pageBreak,
            _p('لا تصح الصلاة بلا طهارة، والصلاه عمود الدين'),
          ].join(),
        ),
      );
      final hits = book.search('الصلاة');
      expect(hits.map((h) => h.page), [1, 2, 2]);
      final s = book.snippet(hits[1]);
      expect(s.match, 'الصلاة');
      expect(book.search('').isEmpty, isTrue);
    });

    test('survives a JSON round trip', () {
      final book = parseDocx(
        _docx([_p('أ', style: '1'), _pageBreak, _p('ب')].join()),
        source: 'x.docx',
      );
      final back = BookText.fromJson(book.toJson());
      expect(back.pages, book.pages);
      expect(back.headings.single.title, 'أ');
      expect(back.source, 'x.docx');
    });

    test('rejects a file that is not Word', () {
      final a = Archive()..add(ArchiveFile.bytes('x.txt', [1, 2, 3]));
      expect(
        () => parseDocx(Uint8List.fromList(ZipEncoder().encode(a))),
        throwsFormatException,
      );
    });
  });

  // The sample files the user provided: المسائل المنتخبة (docx + PDF).
  final sample = File(
    'docs/المسائل المنتخبة - (الطبعة الجديدة المنقحة) - مطابق للأصل.docx',
  );
  group('sample book (المسائل المنتخبة)', () {
    late BookText book;
    setUpAll(() {
      book = parseDocx(sample.readAsBytesSync());
    });

    test('544 pages like the PDF, with its table of contents', () {
      expect(book.pageCount, 544);
      expect(book.headings.length, 199);
      expect(book.headings.first.title, 'المقدّمة');
      expect(book.headings.first.page, 15);
      expect(book.headings.where((h) => h.level == 1).length, 10);
      // Page 24 is the page shown in the phone screenshot.
      expect(book.pages[23], startsWith('بالوجوب فيها وانعكس الأمر'));
    });

    test('search across the whole book is fast', () {
      final sw = Stopwatch()..start();
      final hits = book.search('الوضوء');
      sw.stop();
      expect(hits.length, greaterThan(50));
      expect(hits.any((h) => h.page == 35), isTrue);
      // ignore: avoid_print
      print(
        'search "الوضوء": ${hits.length} hits in ${sw.elapsedMicroseconds} µs',
      );
      expect(sw.elapsedMilliseconds, lessThan(200));
    });
  }, skip: sample.existsSync() ? false : 'sample docx not present');
}
