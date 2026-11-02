import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nots/book/book_text.dart';
import 'package:nots/book/word_map.dart';
import 'package:nots/export/exporter.dart';
import 'package:nots/ink/ink_document.dart';
import 'package:nots/ink/note_items.dart';
import 'package:nots/ink/stroke.dart';
import 'package:nots/ink/words.dart';
import 'package:nots/library/library_store.dart';
import 'package:path/path.dart' as p;

/// A word map like nots-cook writes it (two pages; the second word of page
/// 1 has no place).
Map<String, Object?> sampleMap() => {
  'format': 'nots-words',
  'version': 1,
  'title': 'كتاب',
  'source': {'pdf': 'a.pdf', 'pdfId': '0123456789abcdef', 'text': 'a.docx'},
  'pageCount': 2,
  'wordCount': 5,
  'pages': [
    {
      'k': 'text',
      't': '(مسألة ١): يجوز\nتقليد',
      // word 0 at (100,50)-(140,62); word 1 unknown; word 2 at
      // (60,50)-(90,62); word 3 at (300,80)-(340,92). Tenths of a point,
      // as differences from the previous placed word.
      'b': [1000, 500, 1400, 620, null, -400, 0, -500, 0, 2400, 300, 2500, 300],
    },
    {'k': 'text', 't': 'الأعلم', 'b': [500, 500, 900, 620]},
  ],
  'headings': [
    {'t': 'التقليد', 'l': 1, 'p': 1, 'w': 0},
  ],
};

/// PDF-like bytes holding [json] as a Flate stream marked /NotsWords, the
/// way PyMuPDF writes the attachment.
Uint8List fakePdf(String json, {bool indirectLength = false}) {
  final body = zlib.encode(utf8.encode(json));
  final len = indirectLength ? '99 0 R' : '${body.length}';
  return Uint8List.fromList([
    ...latin1.encode('%PDF-1.7\n1 0 obj\n<</Type/Catalog>>\nendobj\n'),
    ...latin1.encode(
      '7 0 obj\n<</Type/EmbeddedFile/Length $len/Filter/FlateDecode/NotsWords true>>\nstream\n',
    ),
    ...body,
    ...latin1.encode('\nendstream\nendobj\n%%EOF\n'),
  ]);
}

void main() {
  group('word map in a PDF', () {
    test('found by its marker and read back', () {
      final json = jsonEncode(sampleMap());
      expect(findWordMapJson(fakePdf(json)), json);
      expect(findWordMapJson(fakePdf(json, indirectLength: true)), json);
    });

    test('a PDF without a map gives null', () {
      expect(findWordMapJson(Uint8List.fromList(latin1.encode('%PDF-1.4\n%%EOF'))), isNull);
    });

    test('words, places and indices in the whole book', () {
      final book = BookText.fromWordMap(sampleMap());
      expect(book.embedded, isTrue);
      expect(book.sourceId, '0123456789abcdef');
      expect(book.headings.single.title, 'التقليد');
      final l = book.layoutOf(1)!;
      expect(l.length, 4);
      expect(l.rectOf(0), const Rect.fromLTRB(100, 50, 140, 62));
      expect(l.rectOf(1), isNull);
      expect(l.rectOf(2), const Rect.fromLTRB(60, 50, 90, 62));
      expect(l.rectOf(3), const Rect.fromLTRB(300, 80, 340, 92));
      expect(book.layoutOf(2)!.firstWord, 4);
      expect(book.layoutOf(2)!.rectOf(0), const Rect.fromLTRB(50, 50, 90, 62));
    });

    test('a map that does not fit its text gives no places, not wrong ones', () {
      final m = sampleMap();
      ((m['pages'] as List)[1] as Map)['b'] = [1, 2, 3];
      final l = BookText.fromWordMap(m).layoutOf(2)!;
      expect(l.rectOf(0), isNull);
    });

    test('search hits are marked on the words they cover', () {
      final book = BookText.fromWordMap(sampleMap());
      final hits = book.search('يجوز');
      expect(hits.length, 1);
      expect(book.hitRects(hits.single), [const Rect.fromLTRB(60, 50, 90, 62)]);
      // Diacritics and hamza forms do not matter.
      expect(book.search('الاعلم').single.page, 2);
    });

    test('selected words copy as the exact source text', () {
      final book = BookText.fromWordMap(sampleMap());
      final l = book.layoutOf(1)!;
      // A selection starting in the middle of word 0 and covering word 2.
      final ids = l.wordsInRects([const Rect.fromLTRB(55, 51, 125, 61)]);
      expect(ids, [0, 2]);
      expect(l.textOf(book.pages[0], [2, 3]), 'يجوز\nتقليد');
      expect(book.textOfWords(1, 0, 3), '(مسألة ١): يجوز\nتقليد');
    });
  });

  group('saved files', () {
    test('marks keep the indices of their words (ink format 4)', () {
      const mark = NoteItem(
        id: 3,
        kind: ItemKind.mark,
        x: 60,
        y: 50,
        w: 80,
        h: 12,
        style: MarkStyle.underline,
        rects: [Rect.fromLTWH(60, 50, 80, 12)],
        quote: 'يجوز تقليد',
        wordFrom: 51234,
        wordTo: 51235,
      );
      final bytes = StrokeCodec.encodeDocument({}, 4, items: {
        7: [mark],
      });
      final back = StrokeCodec.decodeDocument(bytes).items[7]!.single;
      expect(back.wordFrom, 51234);
      expect(back.wordTo, 51235);
      expect(back.hasWords, isTrue);
      expect(back.quote, 'يجوز تقليد');
    });

    test('files of version 3 (no word indices) still open', () {
      const mark = NoteItem(id: 1, kind: ItemKind.mark, x: 1, y: 2, w: 3, h: 4);
      final v4 = StrokeCodec.encodeDocument({}, 2, items: {
        1: [mark],
      });
      // Version 3 is version 4 without the two trailing word varints.
      final v3 = Uint8List.fromList(v4.sublist(0, v4.length - 2));
      v3[4] = 3;
      final back = StrokeCodec.decodeDocument(v3).items[1]!.single;
      expect(back.wordFrom, -1);
      expect(back.hasWords, isFalse);
    });

    test('a .nots package carries the word map', () async {
      final dir = await Directory.systemTemp.createTemp('nots_pkg_');
      try {
        final json = jsonEncode(sampleMap());
        final pdf = File(p.join(dir.path, 'book.pdf'))
          ..writeAsBytesSync(fakePdf(json));
        final pkg = NotsPackage.read(await exportPackage(
          title: 'كتاب',
          bookId: 'x',
          pdf: pdf,
          ink: InkDocument(),
          linkJson: json,
        ));
        expect(pkg.linkJson, json);
        expect(BookText.fromJson(pkg.linkJson!).embedded, isTrue);
        expect(findWordMapJson(pkg.pdf), json);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  // The real book, when the sample files are on this machine (app/docs is
  // never pushed).
  final cooked = File('docs/arabic-mmontakhab-1441h.nots.pdf');
  final original = File('docs/arabic-mmontakhab-1441h.pdf');
  group('المسائل المنتخبة (linked edition)', () {
    test('map, search, places and table of contents', () {
      final sw = Stopwatch()..start();
      final json = findWordMapJson(cooked.readAsBytesSync());
      final found = sw.elapsedMilliseconds;
      expect(json, isNotNull);
      final book = BookText.fromJson(json!);
      final parsed = sw.elapsedMilliseconds;
      expect(book.pageCount, 544);
      expect(book.layout!.last.firstWord + book.layout!.last.length, 109161);
      expect(book.headings.length, 199);

      sw.reset();
      final hits = book.search('المجتهد الأعلم');
      final searchMs = sw.elapsedMilliseconds;
      expect(hits, isNotEmpty);
      for (final h in hits) {
        expect(book.hitRects(h), isNotEmpty, reason: 'page ${h.page}');
      }
      final page21 = book.search('إذا قلّد مجتهداً يفتي بحرمة العدول').single;
      expect(page21.page, 21);
      final r = book.hitRects(page21);
      expect(r.length, 6);
      for (final x in r) {
        expect(sameLine(x, r.first), isTrue); // one line
      }
      // ignore: avoid_print
      print('map found in $found ms, parsed in ${parsed - found} ms, '
          '${hits.length} hits in $searchMs ms');
    }, skip: !cooked.existsSync());

    test('the map names the original PDF by its book id', () async {
      final book = BookText.fromJson(findWordMapJson(cooked.readAsBytesSync())!);
      expect(book.sourceId, await fingerprintFile(original));
    }, skip: !cooked.existsSync() || !original.existsSync());
  });
}
